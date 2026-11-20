use rookie::chrome;

fn main() {
    let domains = vec!["youtube.com".to_string()];
    let cookies = match chrome(Some(domains)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to extract Chrome cookies: {e}");
            std::process::exit(1);
        }
    };

    println!("# Netscape HTTP Cookie File");

    for cookie in cookies {
        // Format the cookie data according to the Netscape format
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            cookie.domain,
            if cookie.domain.starts_with('.') { "TRUE" } else { "FALSE" },
            cookie.path,
            if cookie.secure { "TRUE" } else { "FALSE" },
            cookie.expires.unwrap_or(0),
            cookie.name,
            cookie.value
        );
    }
}
