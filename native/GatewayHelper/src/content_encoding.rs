//! Strict, bounded HTTP request-body content decoding.
//!
//! Codex Desktop uses zstd for authenticated requests. The other codings mirror the latest
//! cc-switch compatibility set, but this sidecar deliberately rejects stacked codings: accepting
//! a single transform keeps both the compressed and decompressed budgets unambiguous.

use bytes::Bytes;
use http::{header, HeaderMap};
use std::io::Read;
use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ContentCoding {
    Gzip,
    Deflate,
    Brotli,
    Zstd,
}

impl ContentCoding {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "gzip" | "x-gzip" => Some(Self::Gzip),
            "deflate" => Some(Self::Deflate),
            "br" => Some(Self::Brotli),
            "zstd" | "zst" => Some(Self::Zstd),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Gzip => "gzip",
            Self::Deflate => "deflate",
            Self::Brotli => "br",
            Self::Zstd => "zstd",
        }
    }
}

#[derive(Debug, Error)]
pub enum ContentDecodeError {
    #[error("malformed content-encoding header")]
    MalformedHeader,
    #[error("stacked content-encoding is not supported")]
    StackedEncoding,
    #[error("unsupported content-encoding: {0}")]
    UnsupportedEncoding(String),
    #[error("compressed body exceeds {limit} bytes")]
    CompressedTooLarge { limit: usize },
    #[error("decompressed body exceeds {limit} bytes")]
    DecompressedTooLarge { limit: usize },
    #[error("failed to decompress {encoding} body: {source}")]
    InvalidData {
        encoding: &'static str,
        #[source]
        source: std::io::Error,
    },
}

/// Decode one supported request content-coding and remove entity headers that no longer describe
/// the rebuilt body. Both the wire bytes and every decoded output are bounded by `limit`.
pub fn decode_request_body(
    headers: &mut HeaderMap,
    body: Bytes,
    limit: usize,
) -> Result<Bytes, ContentDecodeError> {
    if body.len() > limit {
        return Err(ContentDecodeError::CompressedTooLarge { limit });
    }
    let (declared_count, codings) = content_codings(headers)?;
    if declared_count > 1 {
        return Err(ContentDecodeError::StackedEncoding);
    }
    let Some(coding) = codings.first().copied() else {
        return Ok(body);
    };
    let decoded = decode_single(coding, &body, limit)?;
    headers.remove(header::CONTENT_ENCODING);
    headers.remove(header::CONTENT_LENGTH);
    headers.remove(header::TRANSFER_ENCODING);
    Ok(Bytes::from(decoded))
}

/// Decode a buffered upstream response. Unlike untrusted requests, RFC-stacked response codings
/// are supported and decoded in reverse order, with every intermediate output bounded by `limit`.
pub fn decode_response_body(
    headers: &mut HeaderMap,
    body: Bytes,
    limit: usize,
) -> Result<Bytes, ContentDecodeError> {
    if body.len() > limit {
        return Err(ContentDecodeError::CompressedTooLarge { limit });
    }
    let (_, codings) = content_codings(headers)?;
    if codings.is_empty() {
        return Ok(body);
    }
    let mut decoded = body.to_vec();
    for coding in codings.into_iter().rev() {
        decoded = decode_single(coding, &decoded, limit)?;
    }
    headers.remove(header::CONTENT_ENCODING);
    headers.remove(header::CONTENT_LENGTH);
    headers.remove(header::TRANSFER_ENCODING);
    Ok(Bytes::from(decoded))
}

pub fn has_encoded_body(headers: &HeaderMap) -> Result<bool, ContentDecodeError> {
    content_codings(headers).map(|(_, codings)| !codings.is_empty())
}

fn content_codings(headers: &HeaderMap) -> Result<(usize, Vec<ContentCoding>), ContentDecodeError> {
    if !headers.contains_key(header::CONTENT_ENCODING) {
        return Ok((0, Vec::new()));
    }

    let mut tokens = Vec::new();
    for value in headers.get_all(header::CONTENT_ENCODING) {
        let value = value
            .to_str()
            .map_err(|_| ContentDecodeError::MalformedHeader)?;
        for token in value.split(',') {
            let token = token.trim();
            if token.is_empty() {
                return Err(ContentDecodeError::MalformedHeader);
            }
            tokens.push(token.to_ascii_lowercase());
        }
    }
    let declared_count = tokens.len();
    let mut codings = Vec::new();
    for token in tokens {
        if token == "identity" {
            continue;
        }
        codings.push(
            ContentCoding::parse(&token).ok_or(ContentDecodeError::UnsupportedEncoding(token))?,
        );
    }
    Ok((declared_count, codings))
}

fn decode_single(
    coding: ContentCoding,
    body: &[u8],
    limit: usize,
) -> Result<Vec<u8>, ContentDecodeError> {
    let result = match coding {
        ContentCoding::Gzip => read_bounded(flate2::read::MultiGzDecoder::new(body), limit),
        ContentCoding::Deflate => match read_bounded(flate2::read::ZlibDecoder::new(body), limit) {
            Ok(decoded) => Ok(decoded),
            Err(ReadBoundedError::Io(_)) => {
                read_bounded(flate2::read::DeflateDecoder::new(body), limit)
            }
            Err(error @ ReadBoundedError::TooLarge) => Err(error),
        },
        ContentCoding::Brotli => read_bounded(
            brotli::Decompressor::new(std::io::Cursor::new(body), 4096),
            limit,
        ),
        ContentCoding::Zstd => {
            let decoder =
                zstd::stream::read::Decoder::new(std::io::Cursor::new(body)).map_err(|source| {
                    ContentDecodeError::InvalidData {
                        encoding: coding.label(),
                        source,
                    }
                })?;
            read_bounded(decoder, limit)
        }
    };
    result.map_err(|error| match error {
        ReadBoundedError::TooLarge => ContentDecodeError::DecompressedTooLarge { limit },
        ReadBoundedError::Io(source) => ContentDecodeError::InvalidData {
            encoding: coding.label(),
            source,
        },
    })
}

#[derive(Debug)]
enum ReadBoundedError {
    Io(std::io::Error),
    TooLarge,
}

fn read_bounded(reader: impl Read, limit: usize) -> Result<Vec<u8>, ReadBoundedError> {
    let mut reader = reader.take(limit.saturating_add(1) as u64);
    let mut decoded = Vec::new();
    reader
        .read_to_end(&mut decoded)
        .map_err(ReadBoundedError::Io)?;
    if decoded.len() > limit {
        return Err(ReadBoundedError::TooLarge);
    }
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::HeaderValue;
    use std::io::Write;

    fn headers(encoding: &'static str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(header::CONTENT_ENCODING, HeaderValue::from_static(encoding));
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from_static("1"));
        headers
    }

    #[test]
    fn decodes_every_supported_single_coding() {
        let payload = br#"{"model":"gpt-5.6-sol","input":"hello"}"#;
        let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        gzip.write_all(payload).unwrap();
        let gzip = gzip.finish().unwrap();

        let mut zlib = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        zlib.write_all(payload).unwrap();
        let zlib = zlib.finish().unwrap();

        let mut raw =
            flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
        raw.write_all(payload).unwrap();
        let raw = raw.finish().unwrap();

        let mut brotli = Vec::new();
        {
            let mut writer = brotli::CompressorWriter::new(&mut brotli, 4096, 5, 22);
            writer.write_all(payload).unwrap();
        }
        let zstd = zstd::stream::encode_all(std::io::Cursor::new(payload), 0).unwrap();

        for (encoding, compressed) in [
            ("gzip", gzip),
            ("deflate", zlib),
            ("deflate", raw),
            ("br", brotli),
            ("zstd", zstd),
        ] {
            let mut headers = headers(encoding);
            let decoded = decode_request_body(&mut headers, Bytes::from(compressed), 1024).unwrap();
            assert_eq!(decoded.as_ref(), payload, "{encoding}");
            assert!(!headers.contains_key(header::CONTENT_ENCODING));
            assert!(!headers.contains_key(header::CONTENT_LENGTH));
        }
    }

    #[test]
    fn rejects_stacked_unknown_and_malformed_content_encoding() {
        for encoding in ["gzip, zstd", "identity, zstd", "gzip,", "snappy"] {
            let mut headers = headers(encoding);
            let error =
                decode_request_body(&mut headers, Bytes::from_static(b"body"), 1024).unwrap_err();
            match encoding {
                "gzip, zstd" | "identity, zstd" => {
                    assert!(matches!(error, ContentDecodeError::StackedEncoding))
                }
                "gzip," => assert!(matches!(error, ContentDecodeError::MalformedHeader)),
                _ => assert!(matches!(error, ContentDecodeError::UnsupportedEncoding(_))),
            }
        }

        let mut repeated = HeaderMap::new();
        repeated.append(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
        repeated.append(header::CONTENT_ENCODING, HeaderValue::from_static("zstd"));
        assert!(matches!(
            decode_request_body(&mut repeated, Bytes::from_static(b"body"), 1024),
            Err(ContentDecodeError::StackedEncoding)
        ));
    }

    #[test]
    fn enforces_compressed_and_decompressed_limits_before_full_expansion() {
        let mut plain_headers = HeaderMap::new();
        assert!(matches!(
            decode_request_body(&mut plain_headers, Bytes::from(vec![0; 1025]), 1024),
            Err(ContentDecodeError::CompressedTooLarge { limit: 1024 })
        ));

        let payload = vec![0u8; 8 * 1024 * 1024];
        let compressed = zstd::stream::encode_all(std::io::Cursor::new(payload), 0).unwrap();
        assert!(compressed.len() < 1024);
        let mut headers = headers("zstd");
        assert!(matches!(
            decode_request_body(&mut headers, Bytes::from(compressed), 1024),
            Err(ContentDecodeError::DecompressedTooLarge { limit: 1024 })
        ));
    }

    #[test]
    fn malformed_compressed_data_fails_closed_and_identity_is_untouched() {
        let mut zstd_headers = headers("zstd");
        assert!(matches!(
            decode_request_body(&mut zstd_headers, Bytes::from_static(b"not-zstd"), 1024),
            Err(ContentDecodeError::InvalidData { .. })
        ));
        assert!(zstd_headers.contains_key(header::CONTENT_ENCODING));

        let mut identity_headers = headers("identity");
        let body = Bytes::from_static(br#"{"ok":true}"#);
        assert_eq!(
            decode_request_body(&mut identity_headers, body.clone(), 1024).unwrap(),
            body
        );
        assert!(identity_headers.contains_key(header::CONTENT_ENCODING));
    }

    #[test]
    fn bounded_response_decoding_supports_rfc_stacked_codings_and_strips_headers() {
        let payload = br#"{"ok":true}"#;
        let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        gzip.write_all(payload).unwrap();
        let gzip = gzip.finish().unwrap();
        let stacked = zstd::stream::encode_all(std::io::Cursor::new(gzip), 0).unwrap();
        let mut headers = headers("gzip, zstd");

        let decoded = decode_response_body(&mut headers, Bytes::from(stacked), 1024).unwrap();

        assert_eq!(decoded.as_ref(), payload);
        assert!(!headers.contains_key(header::CONTENT_ENCODING));
        assert!(!headers.contains_key(header::CONTENT_LENGTH));
    }
}
