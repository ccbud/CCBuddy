//! HTTP/1.1 upstream transport with exact inbound header-name casing preservation.
//!
//! The primary path follows cc-switch's raw-write design: serialize the request head ourselves,
//! then use Hyper only to parse the response. A `WriteFilter` discards Hyper's dummy request bytes
//! after the real request has already been written to the socket.

use crate::error::GatewayError;
use crate::header_case::OriginalHeaderCases;
use bytes::{Bytes, BytesMut};
use futures::{Stream, StreamExt};
use http::{HeaderMap, Method, Uri};
use http_body_util::{BodyExt, Full};
use hyper_rustls::HttpsConnectorBuilder;
use hyper_util::{client::legacy::Client, rt::TokioExecutor};
use std::collections::{HashMap, HashSet};
use std::pin::Pin;
use std::sync::OnceLock;
use std::time::Duration;

pub enum UpstreamResponse {
    Hyper(hyper::Response<hyper::body::Incoming>),
    Reqwest(reqwest::Response),
    Buffered {
        status: http::StatusCode,
        headers: HeaderMap,
        body: Bytes,
    },
    Streamed {
        status: http::StatusCode,
        headers: HeaderMap,
        stream: Pin<Box<dyn Stream<Item = Result<Bytes, std::io::Error>> + Send>>,
    },
}

impl UpstreamResponse {
    pub fn buffered(status: http::StatusCode, headers: HeaderMap, body: Bytes) -> Self {
        Self::Buffered {
            status,
            headers,
            body,
        }
    }

    pub fn streamed(
        status: http::StatusCode,
        headers: HeaderMap,
        stream: impl Stream<Item = Result<Bytes, std::io::Error>> + Send + 'static,
    ) -> Self {
        Self::Streamed {
            status,
            headers,
            stream: Box::pin(stream),
        }
    }

    pub fn status(&self) -> http::StatusCode {
        match self {
            Self::Hyper(response) => response.status(),
            Self::Reqwest(response) => response.status(),
            Self::Buffered { status, .. } | Self::Streamed { status, .. } => *status,
        }
    }

    pub fn headers(&self) -> &HeaderMap {
        match self {
            Self::Hyper(response) => response.headers(),
            Self::Reqwest(response) => response.headers(),
            Self::Buffered { headers, .. } | Self::Streamed { headers, .. } => headers,
        }
    }

    pub fn is_sse(&self) -> bool {
        self.headers()
            .get(http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.contains("text/event-stream"))
    }

    pub async fn bytes_with_limit(self, limit: usize) -> Result<Bytes, GatewayError> {
        match self {
            Self::Buffered { body, .. } => {
                if body.len() > limit {
                    return Err(GatewayError::ResponseTooLarge(limit));
                }
                Ok(body)
            }
            response => {
                let mut stream = response.bytes_stream();
                let mut body = BytesMut::new();
                while let Some(chunk) = stream.next().await {
                    let chunk = chunk.map_err(|error| GatewayError::Upstream(error.to_string()))?;
                    if body.len().saturating_add(chunk.len()) > limit {
                        return Err(GatewayError::ResponseTooLarge(limit));
                    }
                    body.extend_from_slice(&chunk);
                }
                Ok(body.freeze())
            }
        }
    }

    pub fn bytes_stream(self) -> Pin<Box<dyn Stream<Item = Result<Bytes, std::io::Error>> + Send>> {
        match self {
            Self::Hyper(response) => {
                let stream = futures::stream::unfold(response.into_body(), |mut body| async {
                    match body.frame().await {
                        Some(Ok(frame)) => match frame.into_data() {
                            Ok(bytes) => Some((Ok(bytes), body)),
                            Err(_) => Some((Ok(Bytes::new()), body)),
                        },
                        Some(Err(error)) => {
                            Some((Err(std::io::Error::other(error.to_string())), body))
                        }
                        None => None,
                    }
                })
                .filter(|result| {
                    futures::future::ready(!matches!(result, Ok(bytes) if bytes.is_empty()))
                });
                Box::pin(stream)
            }
            Self::Reqwest(response) => Box::pin(
                response
                    .bytes_stream()
                    .map(|result| result.map_err(|error| std::io::Error::other(error.to_string()))),
            ),
            Self::Buffered { body, .. } => Box::pin(futures::stream::once(async move { Ok(body) })),
            Self::Streamed { stream, .. } => stream,
        }
    }

    /// Wait for the first stream chunk while the request is still eligible for failover, then
    /// replay it to the client. This prevents a headers-only 2xx response from being recorded as a
    /// healthy provider before any response data arrives.
    pub async fn prime_stream(self, timeout: Duration) -> Result<Self, GatewayError> {
        let status = self.status();
        let headers = self.headers().clone();
        let mut stream = self.bytes_stream();
        let first = tokio::time::timeout(timeout, stream.next())
            .await
            .map_err(|_| {
                GatewayError::UpstreamTransient(format!(
                    "stream produced no first chunk within {} seconds",
                    timeout.as_secs()
                ))
            })?
            .ok_or_else(|| {
                GatewayError::UpstreamTransient("stream ended before its first chunk".into())
            })?
            .map_err(|error| {
                GatewayError::UpstreamTransient(format!(
                    "failed to read the first stream chunk: {error}"
                ))
            })?;
        Ok(Self::streamed(
            status,
            headers,
            futures::stream::once(async move { Ok(first) }).chain(stream),
        ))
    }
}

pub async fn send_request(
    uri: Uri,
    method: Method,
    headers: HeaderMap,
    original_cases: OriginalHeaderCases,
    body: Vec<u8>,
    timeout: Duration,
    insecure_skip_verify: bool,
) -> Result<UpstreamResponse, GatewayError> {
    if insecure_skip_verify {
        return send_insecure(uri, method, headers, body, timeout).await;
    }
    if !original_cases.cases.is_empty() {
        return tokio::time::timeout(
            timeout,
            send_raw_request(&uri, &method, &headers, &original_cases, &body),
        )
        .await
        .map_err(|_| GatewayError::UpstreamTransient("request timed out".into()))?;
    }
    let request = http::Request::builder()
        .method(method)
        .uri(uri)
        .body(Full::new(Bytes::from(body)))
        .map_err(|error| GatewayError::Http(error.to_string()))?;
    let (mut parts, body) = request.into_parts();
    parts.headers = headers;
    let request = http::Request::from_parts(parts, body);
    let response = tokio::time::timeout(timeout, global_hyper_client().request(request))
        .await
        .map_err(|_| GatewayError::UpstreamTransient("request timed out".into()))?
        .map_err(|error| GatewayError::UpstreamTransient(error.to_string()))?;
    Ok(UpstreamResponse::Hyper(response))
}

async fn send_insecure(
    uri: Uri,
    method: Method,
    headers: HeaderMap,
    body: Vec<u8>,
    timeout: Duration,
) -> Result<UpstreamResponse, GatewayError> {
    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(timeout)
        .build()
        .map_err(|error| GatewayError::UpstreamPermanent(error.to_string()))?;
    let response = client
        .request(method, uri.to_string())
        .headers(headers)
        .body(body)
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() || error.is_connect() || error.is_body() {
                GatewayError::UpstreamTransient(error.to_string())
            } else {
                GatewayError::UpstreamPermanent(error.to_string())
            }
        })?;
    Ok(UpstreamResponse::Reqwest(response))
}

type HyperClient = Client<
    hyper_rustls::HttpsConnector<hyper_util::client::legacy::connect::HttpConnector>,
    Full<Bytes>,
>;

fn global_hyper_client() -> &'static HyperClient {
    static CLIENT: OnceLock<HyperClient> = OnceLock::new();
    CLIENT.get_or_init(|| {
        let connector = HttpsConnectorBuilder::new()
            .with_webpki_roots()
            .https_or_http()
            .enable_http1()
            .build();
        Client::builder(TokioExecutor::new())
            .http1_preserve_header_case(true)
            .http1_title_case_headers(true)
            .build(connector)
    })
}

async fn send_raw_request(
    uri: &Uri,
    method: &Method,
    headers: &HeaderMap,
    original_cases: &OriginalHeaderCases,
    body: &[u8],
) -> Result<UpstreamResponse, GatewayError> {
    use tokio::io::AsyncWriteExt;

    let scheme = uri.scheme_str().unwrap_or("https");
    let host = uri
        .host()
        .ok_or_else(|| GatewayError::UpstreamPermanent("upstream URI has no host".into()))?;
    let port = uri
        .port_u16()
        .unwrap_or(if scheme == "https" { 443 } else { 80 });
    let path = uri.path_and_query().map_or("/", |value| value.as_str());
    let raw = build_raw_request(method, path, headers, original_cases, body);
    let mut tcp = tokio::net::TcpStream::connect((host, port))
        .await
        .map_err(|error| GatewayError::UpstreamTransient(format!("TCP connect failed: {error}")))?;
    tcp.set_nodelay(true)?;
    if scheme == "https" {
        let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|error| {
            GatewayError::UpstreamPermanent(format!("invalid TLS name: {error}"))
        })?;
        let mut stream = global_tls_connector()
            .connect(name, tcp)
            .await
            .map_err(|error| {
                GatewayError::UpstreamPermanent(format!("TLS handshake failed: {error}"))
            })?;
        stream.write_all(&raw).await?;
        stream.flush().await?;
        parse_response(WriteFilter::new(stream), method.clone()).await
    } else {
        tcp.write_all(&raw).await?;
        tcp.flush().await?;
        parse_response(WriteFilter::new(tcp), method.clone()).await
    }
}

fn global_tls_connector() -> &'static tokio_rustls::TlsConnector {
    static CONNECTOR: OnceLock<tokio_rustls::TlsConnector> = OnceLock::new();
    CONNECTOR.get_or_init(|| {
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let native = rustls_native_certs::load_native_certs();
        roots.add_parsable_certificates(native.certs);
        let config = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        tokio_rustls::TlsConnector::from(std::sync::Arc::new(config))
    })
}

fn build_raw_request(
    method: &Method,
    path: &str,
    headers: &HeaderMap,
    original_cases: &OriginalHeaderCases,
    body: &[u8],
) -> Vec<u8> {
    let mut raw = Vec::with_capacity(4096 + body.len());
    raw.extend_from_slice(method.as_str().as_bytes());
    raw.extend_from_slice(b" ");
    raw.extend_from_slice(path.as_bytes());
    raw.extend_from_slice(b" HTTP/1.1\r\n");

    let mut emitted = HashSet::with_capacity(original_cases.cases.len());
    let mut cursors: HashMap<String, usize> = HashMap::new();
    for (lower, original) in &original_cases.cases {
        let Ok(name) = http::header::HeaderName::from_bytes(lower.as_bytes()) else {
            continue;
        };
        let values: Vec<_> = headers.get_all(&name).iter().collect();
        let cursor = cursors.entry(lower.clone()).or_default();
        if let Some(value) = values.get(*cursor) {
            raw.extend_from_slice(original);
            raw.extend_from_slice(b": ");
            raw.extend_from_slice(value.as_bytes());
            raw.extend_from_slice(b"\r\n");
            *cursor += 1;
            emitted.insert(lower.clone());
        }
    }
    for name in headers.keys() {
        let lower = name.as_str().to_ascii_lowercase();
        if emitted.contains(&lower) {
            continue;
        }
        for value in headers.get_all(name) {
            raw.extend_from_slice(name.as_str().as_bytes());
            raw.extend_from_slice(b": ");
            raw.extend_from_slice(value.as_bytes());
            raw.extend_from_slice(b"\r\n");
        }
        emitted.insert(lower);
    }
    if !headers.contains_key(http::header::CONTENT_LENGTH) {
        raw.extend_from_slice(b"Content-Length: ");
        raw.extend_from_slice(body.len().to_string().as_bytes());
        raw.extend_from_slice(b"\r\n");
    }
    raw.extend_from_slice(b"\r\n");
    raw.extend_from_slice(body);
    raw
}

async fn parse_response<S>(
    stream: WriteFilter<S>,
    method: Method,
) -> Result<UpstreamResponse, GatewayError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let io = hyper_util::rt::TokioIo::new(stream);
    let (mut sender, connection) = hyper::client::conn::http1::Builder::new()
        .preserve_header_case(true)
        .handshake::<_, Full<Bytes>>(io)
        .await
        .map_err(|error| {
            GatewayError::UpstreamTransient(format!("response handshake failed: {error}"))
        })?;
    tokio::spawn(async move {
        let _ = connection.await;
    });
    let dummy = http::Request::builder()
        .method(method)
        .uri("/")
        .body(Full::new(Bytes::new()))
        .map_err(|error| GatewayError::Http(error.to_string()))?;
    let response = sender.send_request(dummy).await.map_err(|error| {
        GatewayError::UpstreamTransient(format!("response parse failed: {error}"))
    })?;
    Ok(UpstreamResponse::Hyper(response))
}

struct WriteFilter<S> {
    inner: S,
}

impl<S> WriteFilter<S> {
    fn new(inner: S) -> Self {
        Self { inner }
    }
}

impl<S: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for WriteFilter<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        context: &mut std::task::Context<'_>,
        buffer: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_read(context, buffer)
    }
}

impl<S: Unpin> tokio::io::AsyncWrite for WriteFilter<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        _context: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::task::Poll::Ready(Ok(bytes.len()))
    }

    fn poll_flush(
        self: Pin<&mut Self>,
        _context: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        _context: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_request_keeps_original_order_case_and_rewritten_values() {
        let mut headers = HeaderMap::new();
        headers.append("x-api-key", "new-one".parse().unwrap());
        headers.append("x-api-key", "new-two".parse().unwrap());
        headers.insert("host", "example.com".parse().unwrap());
        let cases = OriginalHeaderCases {
            cases: vec![
                ("x-api-key".into(), b"X-API-Key".to_vec()),
                ("x-api-key".into(), b"x-api-key".to_vec()),
            ],
        };
        let raw = build_raw_request(&Method::POST, "/v1/messages", &headers, &cases, b"{}");
        let text = String::from_utf8(raw).unwrap();
        assert!(text.contains("X-API-Key: new-one\r\nx-api-key: new-two\r\n"));
        assert!(text.contains("host: example.com\r\n"));
        assert!(text.ends_with("\r\n\r\n{}"));
    }
}
