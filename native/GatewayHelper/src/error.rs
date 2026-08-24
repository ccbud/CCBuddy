use thiserror::Error;

#[derive(Debug, Error)]
pub enum GatewayError {
    #[error("configuration error: {0}")]
    Config(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("HTTP error: {0}")]
    Http(String),
    #[error("upstream error: {0}")]
    Upstream(String),
    #[error("transient upstream error: {0}")]
    UpstreamTransient(String),
    #[error("permanent upstream transport error: {0}")]
    UpstreamPermanent(String),
    #[error("protocol conversion error: {0}")]
    Protocol(String),
    #[error("all configured providers are unavailable")]
    NoProvider,
    #[error("response body exceeded {0} bytes")]
    ResponseTooLarge(usize),
}
