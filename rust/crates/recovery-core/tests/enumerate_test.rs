//! Real-device enumeration smoke + unit tests.
//!
//! The `strict` smoke variant asserts that at least one real block device
//! is found. CI sets FRF_ENUM_STRICT=1 on runner jobs (every GitHub runner
//! exposes its own disks), while containers/VMs without block nodes pass
//! the soft variant so local runs never fail on hardware quirks.

use recovery_core::enumerate;

fn strict() -> bool {
    std::env::var("FRF_ENUM_STRICT").map(|v| v == "1").unwrap_or(false)
}

#[test]
fn enumerate_never_panics_and_is_sane() {
    let devs = enumerate::enumerate();
    for d in &devs {
        assert!(!d.id.is_empty(), "id must be set: {d:?}");
        assert!(!d.path.is_empty(), "path must be set: {d:?}");
        assert!(d.total > 0 || d.mounted, "size or mounted required: {d:?}");
        assert!(d.kind <= 3, "kind must be a device kind (not image): {d:?}");
        // ids are unique across the whole enumeration
    }
    let mut ids: Vec<_> = devs.iter().map(|d| d.id.clone()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), devs.len(), "device ids must be unique");
}

#[cfg(target_os = "linux")]
#[test]
fn linux_finds_block_nodes() {
    let devs = enumerate::enumerate();
    // No hard failure without block nodes (containers); with them, sanity.
    if devs.is_empty() {
        assert!(!strict(), "FRF_ENUM_STRICT=1 but sysfs enumeration was empty");
        return;
    }
    let disks: Vec<_> = devs.iter().filter(|d| d.id.starts_with("blk")).collect();
    if strict() {
        assert!(!disks.is_empty(), "runner must expose at least one real disk");
    }
    for d in &disks {
        assert!(d.path.starts_with("/dev/"));
        assert!(d.total > 0);
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_partitions_map_to_parents() {
    use recovery_core::enumerate::parent_disk_of;
    assert_eq!(parent_disk_of("nvme0n1p2"), "nvme0n1");
    assert_eq!(parent_disk_of("sda1"), "sda");
}

#[cfg(target_os = "macos")]
#[test]
fn macos_finds_disks() {
    let devs = enumerate::enumerate();
    if strict() {
        assert!(!devs.is_empty(), "runner must expose at least one IOMedia disk");
    }
    // The boot disk must be marked as system when found.
    if let Some(d) = devs.iter().find(|d| d.mount == "/") {
        assert!(d.is_system || d.id.starts_with("bsd"), "root volume flagged: {d:?}");
    }
}

#[cfg(target_os = "windows")]
#[test]
fn windows_finds_physical_drives() {
    let devs = enumerate::enumerate();
    if strict() {
        assert!(!devs.is_empty(), "runner must expose at least one physical drive");
    }
    // The system drive's disk must be flagged (SystemDrive -> GET_DEVICE_NUMBER).
    if let Some(d) = devs.iter().find(|d| d.is_system) {
        assert!(d.path.starts_with("\\\\.\\PhysicalDrive"), "{d:?}");
    }
}
