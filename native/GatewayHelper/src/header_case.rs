//! Original HTTP header-name casing captured before Hyper normalizes names.
//!
//! This mirrors cc-switch's raw `TcpStream::peek` boundary. The ordered representation also keeps
//! duplicate header order stable when the request is written upstream.

#[derive(Clone, Debug, Default)]
pub struct OriginalHeaderCases {
    pub cases: Vec<(String, Vec<u8>)>,
}

impl OriginalHeaderCases {
    pub fn from_raw_bytes(bytes: &[u8]) -> Self {
        let mut storage = [httparse::EMPTY_HEADER; 128];
        let mut request = httparse::Request::new(&mut storage);
        let _ = request.parse(bytes);
        let cases = request
            .headers
            .iter()
            .take_while(|header| !header.name.is_empty())
            .map(|header| {
                (
                    header.name.to_ascii_lowercase(),
                    header.name.as_bytes().to_vec(),
                )
            })
            .collect();
        Self { cases }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_order_duplicates_and_exact_case() {
        let cases = OriginalHeaderCases::from_raw_bytes(
            b"POST /v1/messages HTTP/1.1\r\nX-API-Key: a\r\nx-api-key: b\r\nContent-Type: application/json\r\n\r\n",
        );
        assert_eq!(
            cases.cases,
            vec![
                ("x-api-key".into(), b"X-API-Key".to_vec()),
                ("x-api-key".into(), b"x-api-key".to_vec()),
                ("content-type".into(), b"Content-Type".to_vec()),
            ]
        );
    }
}
