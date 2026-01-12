use actix_web::{body::BoxBody, http::header, web, App, HttpResponse, HttpServer};

const BLOB_SIZE: usize = 1024 * 1024;
static BLOB: [u8; BLOB_SIZE] = [0; BLOB_SIZE];

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    HttpServer::new(|| {
        App::new()
            .route("/health", web::get().to(health))
            .route("/echo", web::get().to(echo_get))
            .route("/echo", web::post().to(echo_post))
            .route("/blob", web::get().to(blob))
    })
    .workers(2)
    .bind(("0.0.0.0", 8080))?
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
        .insert_header((header::CONTENT_TYPE, "application/octet-stream"))
        .body(body)
}

async fn blob() -> HttpResponse<BoxBody> {
    HttpResponse::Ok()
        .insert_header((header::CONTENT_TYPE, "application/octet-stream"))
        .body(&BLOB[..])
}
