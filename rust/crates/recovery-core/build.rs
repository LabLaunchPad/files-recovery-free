//! Link the frameworks the enumerate module's macOS probe needs.
//! (DiskArbitration itself is not linked yet — enumeration rides IOKit.)

fn main() {
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=IOKit");
    }
}
