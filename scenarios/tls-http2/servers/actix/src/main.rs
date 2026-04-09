use actix_web::{body::BoxBody, http::header, web, App, HttpResponse, HttpServer};
use rustls::ServerConfig;
use std::fs::File;
use std::io::BufReader;

const BLOB_SIZE: usize = 8 * 1024;
static BLOB: [u8; BLOB_SIZE] = [0; BLOB_SIZE];

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let cert_file = &mut BufReader::new(File::open("/app/certs/server.crt").unwrap());
    let key_file = &mut BufReader::new(File::open("/app/certs/server.key").unwrap());

    let certs: Vec<_> = rustls_pemfile::certs(cert_file)
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let key = rustls_pemfile::private_key(key_file).unwrap().unwrap();

    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .unwrap();

    HttpServer::new(|| {
        App::new()
            .route("/health", web::get().to(health))
            .route("/echo", web::get().to(echo_get))
            .route("/echo", web::post().to(echo_post))
            .route("/blob", web::get().to(blob))
    })
    .workers(2)
    .bind_rustls_0_23(("0.0.0.0", 8443), config)?
    .run()
    .await
}

async fn health() -> HttpResponse<BoxBody> {
    HttpResponse::Ok().finish()
}

async fn echo_get() -> HttpResponse<BoxBody> {
    HttpResponse::Ok()
        .insert_header((header::CONTENT_TYPE, "application/json"))
        .body("{\"status\":\"ok\"}")
}

async fn echo_post(body: web::Bytes) -> HttpResponse<BoxBody> {
    HttpResponse::Ok()
        .insert_header((header::CONTENT_TYPE, "application/json"))
        .body(body)
}

async fn blob() -> HttpResponse<BoxBody> {
    HttpResponse::Ok()
        .insert_header((header::CONTENT_TYPE, "application/octet-stream"))
        .body(&BLOB[..])
}
