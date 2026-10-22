fn main() {
    let key = "FRF1-RlJG-UFJP-MQEM-UQAA-AAAA-AAAA-AADh-uwuR-/iVo-P3WD-mrXM-LQMu-/B0B-Elr1-jQf6-JYnO-0x2i-aki0-54WP-8Dtn-XBPC-Fm/A-qe1x-nyK2-aU+H-/9jE-NY7k-vk8L";
    let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() / 86400) as u32;
    match recovery_core::license::verify_license_key(key, &recovery_core::license::default_pubkey(), now) {
        Ok(info) => println!("VALID perpetual={} issued={} expiry={}", info.perpetual, info.issued_days, info.expiry_days),
        Err(e) => println!("INVALID {:?}", e),
    }
}
