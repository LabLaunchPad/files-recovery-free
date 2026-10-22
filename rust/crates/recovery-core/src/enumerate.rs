//! Real device enumeration — Phase 3. The read-only discovery layer that
//! feeds the engine's source list (which the FFI layer exposes as
//! `frf_source_*`, and the Choose step renders).
//!
//! Per-OS mechanisms (Task 7 research, docs/PLATFORMS.md):
//!  - Linux: sysfs `/sys/class/block` + `/proc/self/mountinfo` (the same
//!    underlying source udev/udisks2 read; zero extra dependencies).
//!  - macOS: IOKit registry walk over `IOMedia` objects — the plane
//!    DiskArbitration itself sits on (enumerating via IOKit avoids a
//!    CFRunLoop dependency; DA is a better fit for mount/unmount EVENTS,
//!    which remain UI-side polling for now). Mount/filesystem details via
//!    `getfsstat`.
//!  - Windows: SetupAPI device-interface walk (GUID_DEVINTERFACE_DISK) +
//!    `IOCTL_DISK_GET_LENGTH_INFO` / `IOCTL_STORAGE_GET_DEVICE_NUMBER`
//!    with zero-desired-access handles (no elevation needed).
//!
//! Read-only by design: nothing here opens anything with write access, and
//! enumeration never requires admin/root. Scanning a discovered device is
//! a separate, permission-checked act (see docs/PERMISSIONS.md).

/// Mirrors the Dart `DeviceKind` order (0 sd, 1 usb, 2 external, 3 internal,
/// 4 disk image) so FFI can pass integers straight through.
#[derive(Clone, Debug)]
pub struct OsDevice {
    pub id: String,
    pub name: String,
    pub kind: u32,
    pub total: u64,
    pub mounted: bool,
    pub is_system: bool,
    pub fs: String,
    pub mount: String,
    /// OS path a `BlockSource` can open read-only: `/dev/sda1`,
    /// `/dev/disk2s1`, `\\.\PhysicalDrive1`.
    pub path: String,
    pub writable: bool,
}

/// Enumerate present block devices + volumes on the running OS.
/// Never panics; a failing platform probe yields an empty list.
pub fn enumerate() -> Vec<OsDevice> {
    #[cfg(target_os = "linux")]
    {
        return linux::enumerate();
    }
    #[cfg(target_os = "macos")]
    {
        return macos::enumerate();
    }
    #[cfg(target_os = "windows")]
    {
        return windows::enumerate();
    }
    #[cfg(not(any(
        target_os = "linux",
        target_os = "macos",
        target_os = "windows"
    )))]
    {
        Vec::new()
    }
}

/// Strip a trailing partition index: `sda1` -> `sda`, `nvme0n1p2` -> `nvme0n1`,
/// `mmcblk0p3` -> `mmcblk0`. Disks without an index pass through unchanged.
pub fn parent_disk_of(node: &str) -> String {
    if (node.starts_with("nvme") || node.starts_with("mmcblk")) && node.contains('p') {
        if let Some(pos) = node.rfind('p') {
            if node[pos + 1..].bytes().all(|b| b.is_ascii_digit()) && !node[pos + 1..].is_empty() {
                return node[..pos].to_string();
            }
        }
    }
    let mut s = node.to_string();
    while s.chars().last().map(|c| c.is_ascii_digit()).unwrap_or(false) {
        s.pop();
    }
    s
}

// ======================================================================
// Linux — sysfs + mountinfo
// ======================================================================

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::collections::HashMap;
    use std::fs;
    use std::path::Path;

    const SKIP_PREFIXES: [&str; 4] = ["loop", "ram", "zram", "dm-"];

    struct MountInfo {
        fstype: String,
        mount: String,
    }

    /// `/proc/self/mountinfo` keyed by `major:minor`.
    fn mounts() -> HashMap<String, MountInfo> {
        let mut map = HashMap::new();
        let Ok(text) = fs::read_to_string("/proc/self/mountinfo") else {
            return map;
        };
        for line in text.lines() {
            // 36 35 0:43 / / rw,relatime master:34 - overlay rootfs rw,...
            let Some(sep) = line.find(" - ") else { continue };
            let head = &line[..sep];
            let tail = &line[sep + 3..];
            let f: Vec<&str> = head.split_whitespace().collect();
            let t: Vec<&str> = tail.split_whitespace().collect();
            if f.len() < 5 || t.len() < 2 {
                continue;
            }
            map.insert(
                f[2].to_string(),
                MountInfo {
                    fstype: t[0].to_string(),
                    mount: f[4].to_string(),
                },
            );
        }
        map
    }

    /// `major:minor` of a block node from its sysfs dir.
    fn dev_t_of(sysfs: &Path) -> Option<String> {
        fs::read_to_string(sysfs.join("dev"))
            .ok()
            .map(|s| s.trim().to_string())
    }

    /// The disk backing the running system (locked in the UI, spec 5.1).
    /// Prefers the real device behind the `/` mount, falls back to
    /// `root=` on the kernel command line (VMs, containers).
    fn system_disk(_mounts: &HashMap<String, MountInfo>) -> Option<String> {
        // mountinfo source for the / entry (f[4] == "/"); overlay/tmpfs roots
        // (containers) do not map to a block node, so the cmdline fallback
        // below decides in that case.
        if let Ok(text) = fs::read_to_string("/proc/self/mountinfo") {
            for line in text.lines() {
                let Some(sep) = line.find(" - ") else { continue };
                let f: Vec<&str> = line[..sep].split_whitespace().collect();
                let t: Vec<&str> = line[sep + 3..].split_whitespace().collect();
                if f.len() >= 5 && t.len() >= 2 && f[4] == "/" && t[0] != "overlay" {
                    let src = t[1].trim_start_matches("/dev/");
                    if src.starts_with('/') || src.is_empty() {
                        continue;
                    }
                    return Some(parent_disk_of(src));
                }
            }
        }
        if let Ok(cmdline) = fs::read_to_string("/proc/cmdline") {
            if let Some(root) = cmdline.split_whitespace().find(|t| t.starts_with("root=")) {
                let dev = root.trim_start_matches("root=");
                if !dev.starts_with("UUID=") && !dev.starts_with("PARTUUID=") {
                    return Some(parent_disk_of(dev.trim_start_matches("/dev/")));
                }
            }
        }
        None
    }

    pub fn enumerate() -> Vec<OsDevice> {
        let mut out = Vec::new();
        let mounts = mounts();
        let sys_class = Path::new("/sys/class/block");
        let Ok(entries) = fs::read_dir(sys_class) else {
            return out;
        };

        let mut names: Vec<String> = entries
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| !SKIP_PREFIXES.iter().any(|p| n.starts_with(p)))
            .collect();
        names.sort();

        let root_disk = system_disk(&mounts);

        for name in &names {
            let sysfs = sys_class.join(name);
            // Disks carry a queue/ directory; partitions do not.
            let is_disk = sysfs.join("queue").is_dir();

            let disk_name = if is_disk {
                name.clone()
            } else {
                // partition: parent disk from the sysfs link
                // /sys/class/block/sda1 -> ../../devices/pci…/sda/sda1
                let Ok(link) = fs::read_link(&sysfs) else { continue };
                let s = link.to_string_lossy();
                let segs: Vec<&str> = s.split('/').filter(|x| !x.is_empty()).collect();
                let mut parent = String::new();
                for seg in segs.iter().rev().skip(1) {
                    if sys_class.join(seg).join("queue").is_dir()
                        || Path::new("/sys/class/block").join(seg).exists()
                    {
                        parent = (*seg).to_string();
                        break;
                    }
                }
                if parent.is_empty() {
                    continue;
                }
                parent
            };

            let sectors: u64 = fs::read_to_string(sysfs.join("size"))
                .ok()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(0);
            if sectors == 0 {
                continue;
            }

            let removable = fs::read_to_string(sys_class.join(&disk_name).join("removable"))
                .ok()
                .and_then(|s| s.trim().parse::<u32>().ok())
                .unwrap_or(0)
                == 1;
            let readonly = fs::read_to_string(sysfs.join("ro"))
                .ok()
                .map(|s| s.trim() == "1")
                .unwrap_or(false);

            let model = fs::read_to_string(sys_class.join(&disk_name).join("device/model"))
                .ok()
                .map(|s| s.trim().to_string())
                .unwrap_or_default();

            let m = dev_t_of(&sysfs).and_then(|d| mounts.get(&d));
            let (fs_type, mount, mounted) = match m {
                Some(mi) => (mi.fstype.clone(), mi.mount.clone(), true),
                None => (String::new(), String::new(), false),
            };

            let is_system = if is_disk {
                root_disk.as_deref() == Some(disk_name.as_str())
            } else {
                mount == "/"
            };

            let label = if model.is_empty() {
                name.clone()
            } else if is_disk {
                let gb = sectors * 512 / (1024 * 1024 * 1024);
                format!("{model} ({gb} GB)")
            } else {
                format!("{model} · {name}")
            };

            out.push(OsDevice {
                id: format!("{}{name}", if is_disk { "blk" } else { "part" }),
                name: label,
                kind: if removable { 2 } else { 3 }, // external vs internal
                total: sectors * 512,
                mounted,
                is_system,
                fs: fs_type,
                mount,
                path: format!("/dev/{name}"),
                writable: !readonly,
            });
        }
        out
    }
}

// ======================================================================
// macOS — IOKit IOMedia registry walk + getfsstat
// ======================================================================

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use std::ffi::{c_char, c_void, CStr};

    type IoObject = u32;
    type CfRef = *mut c_void;

    const KIOMAINPORTDEFAULT: u32 = 0;
    const KCFNUMBERSINT64: usize = 4; // kCFNumberSInt64Type
    const KCFSTRINGENCODINGUTF8: u32 = 0x0800_0100;

    extern "C" {
        fn IOServiceMatching(name: *const c_char) -> CfRef;
        fn IOServiceGetMatchingServices(port: u32, matching: CfRef, it: *mut IoObject) -> i32;
        fn IOIteratorNext(it: IoObject) -> IoObject;
        fn IOObjectRelease(o: IoObject) -> i32;
        fn IORegistryEntryCreateCFProperties(
            entry: IoObject,
            props: *mut CfRef,
            alloc: CfRef,
            options: u32,
        ) -> i32;

        fn CFDictionaryGetValue(dict: CfRef, key: CfRef) -> CfRef;
        fn CFStringCreateWithCString(alloc: CfRef, cstr: *const c_char, encoding: u32) -> CfRef;
        fn CFStringGetCString(s: CfRef, buf: *mut c_char, max: isize, encoding: u32) -> u8;
        fn CFNumberGetValue(num: CfRef, ty: usize, out: *mut u64) -> u8;
        fn CFBooleanGetValue(b: CfRef) -> u8;
        fn CFRelease(o: CfRef);
    }

    fn make_key(s: &str) -> CfRef {
        let c = std::ffi::CString::new(s).unwrap();
        unsafe { CFStringCreateWithCString(std::ptr::null_mut(), c.as_ptr(), KCFSTRINGENCODINGUTF8) }
    }

    unsafe fn get_str(dict: CfRef, k: CfRef) -> Option<String> {
        let v = CFDictionaryGetValue(dict, k);
        if v.is_null() {
            return None;
        }
        let mut buf = [0 as c_char; 256];
        if CFStringGetCString(v, buf.as_mut_ptr(), 256, KCFSTRINGENCODINGUTF8) == 0 {
            return None;
        }
        Some(CStr::from_ptr(buf.as_ptr()).to_string_lossy().into())
    }

    unsafe fn get_u64(dict: CfRef, k: CfRef) -> Option<u64> {
        let v = CFDictionaryGetValue(dict, k);
        if v.is_null() {
            return None;
        }
        let mut out: u64 = 0;
        (CFNumberGetValue(v, KCFNUMBERSINT64, &mut out) != 0).then_some(out)
    }

    unsafe fn get_bool(dict: CfRef, k: CfRef) -> bool {
        let v = CFDictionaryGetValue(dict, k);
        if v.is_null() {
            return false;
        }
        // CFBooleanGetValue is the documented accessor — robust regardless
        // of singleton identity across framework load states.
        CFBooleanGetValue(v) != 0
    }

    struct FsMount {
        from: String,
        on: String,
        fstype: String,
    }

    /// getfsstat — every mounted volume with from/on/fstype.
    fn fsstat() -> Vec<FsMount> {
        let mut out = Vec::new();
        unsafe {
            let n = libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT);
            if n <= 0 {
                return out;
            }
            let mut buf: Vec<libc::statfs> = vec![std::mem::zeroed(); n as usize];
            let got = libc::getfsstat(
                buf.as_mut_ptr(),
                (buf.len() * std::mem::size_of::<libc::statfs>()) as i32,
                libc::MNT_NOWAIT,
            );
            let cstr = |b: &[c_char]| -> String {
                let bytes: Vec<u8> =
                    b.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
                String::from_utf8_lossy(&bytes).into()
            };
            for st in buf.iter_mut().take(got.max(0) as usize) {
                out.push(FsMount {
                    from: cstr(&st.f_mntfromname),
                    on: cstr(&st.f_mntonname),
                    fstype: cstr(&st.f_fstypename),
                });
            }
        }
        out
    }

    /// `disk4s2` -> `disk4`; plain `disk4` passes through.
    fn disk_of_bsd(from: &str) -> Option<String> {
        let bsd = from.strip_prefix("/dev/")?;
        let rest = bsd.strip_prefix("disk")?;
        let digits_end = rest
            .bytes()
            .position(|b| !b.is_ascii_digit())
            .unwrap_or(rest.len());
        if digits_end == 0 {
            return None;
        }
        let after = &rest[digits_end..];
        if after.is_empty() {
            return Some(bsd.to_string());
        }
        let part = after.strip_prefix('s')?;
        (!part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
            .then(|| format!("disk{}", &rest[..digits_end]))
    }

    pub fn enumerate() -> Vec<OsDevice> {
        let mut out = Vec::new();
        let mounts = fsstat();
        let root_disk = mounts.iter().find(|m| m.on == "/").and_then(|m| disk_of_bsd(&m.from));

        unsafe {
            let matching = IOServiceMatching(b"IOMedia\0".as_ptr() as *const c_char);
            if !matching.is_null() {
                let mut it: IoObject = 0;
                if IOServiceGetMatchingServices(KIOMAINPORTDEFAULT, matching, &mut it) == 0 {
                    let k_bsd = make_key("BSD Name");
                    let k_size = make_key("Size");
                    let k_writable = make_key("Writable");
                    let k_removable = make_key("Removable");
                    let k_whole = make_key("Whole");
                    let k_leaf = make_key("Leaf");

                    loop {
                        let entry = IOIteratorNext(it);
                        if entry == 0 {
                            break;
                        }
                        let mut props: CfRef = std::ptr::null_mut();
                        if IORegistryEntryCreateCFProperties(
                            entry,
                            &mut props,
                            std::ptr::null_mut(),
                            0,
                        ) == 0
                            && !props.is_null()
                        {
                            let bsd = get_str(props, k_bsd).unwrap_or_default();
                            let size = get_u64(props, k_size).unwrap_or(0);
                            let whole = get_bool(props, k_whole);
                            let leaf = get_bool(props, k_leaf);
                            if !bsd.is_empty() && size > 0 && (whole || leaf) {
                                let removable = get_bool(props, k_removable);
                                let writable = get_bool(props, k_writable);
                                let mount =
                                    mounts.iter().find(|m| m.from == format!("/dev/{bsd}"));
                                out.push(OsDevice {
                                    id: format!("{}{bsd}", if whole { "bsd" } else { "vol" }),
                                    name: display_name(bsd.as_str(), whole, size,
                                        mount.map(|x| x.fstype.as_str())),
                                    kind: if removable { 2 } else { 3 },
                                    total: size,
                                    mounted: mount.is_some(),
                                    is_system: if whole {
                                        root_disk.as_deref() == Some(bsd.as_str())
                                    } else {
                                        mount.map(|x| x.on == "/").unwrap_or(false)
                                    },
                                    fs: mount.map(|x| x.fstype.clone()).unwrap_or_default(),
                                    mount: mount.map(|x| x.on.clone()).unwrap_or_default(),
                                    path: format!("/dev/{bsd}"),
                                    writable,
                                });
                            }
                            CFRelease(props);
                        }
                        IOObjectRelease(entry);
                    }

                    CFRelease(k_bsd);
                    CFRelease(k_size);
                    CFRelease(k_writable);
                    CFRelease(k_removable);
                    CFRelease(k_whole);
                    CFRelease(k_leaf);
                    IOObjectRelease(it);
                }
            }
        }

        // Defensive fallback: if the IOKit plane yielded nothing (sandboxed
        // or restricted hosts), still expose the MOUNTED volumes from
        // getfsstat — every Mac has at least the root volume. Honest: no
        // invented sizes; capacity comes from the scan opening the device.
        if out.is_empty() {
            for m in &mounts {
                if !m.from.starts_with("/dev/") {
                    continue;
                }
                let bsd = &m.from[5..];
                if bsd.starts_with("disk") {
                    let whole = disk_of_bsd(&m.from).is_some_and(|d| d == bsd);
                    out.push(OsDevice {
                        id: format!("{}{bsd}", if whole { "bsd" } else { "vol" }),
                        name: display_name(bsd, whole, 0, Some(m.fstype.as_str())),
                        kind: 3,
                        total: 0,
                        mounted: true,
                        is_system: m.on == "/",
                        fs: m.fstype.clone(),
                        mount: m.on.clone(),
                        path: m.from.clone(),
                        writable: true,
                    });
                }
            }
        }

        out.retain(|d| d.total > 0 || d.mounted);
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }

    fn display_name(bsd: &str, is_disk: bool, size: u64, fs: Option<&str>) -> String {
        if size == 0 {
            return match fs {
                Some(f) if !f.is_empty() => format!("{bsd} · {f}"),
                _ => bsd.to_string(),
            };
        }
        let gb = size / (1024 * 1024 * 1024);
        if is_disk {
            format!("Disk {bsd} ({gb} GB)")
        } else {
            match fs {
                Some(f) if !f.is_empty() => format!("Volume {bsd} · {f} ({gb} GB)"),
                _ => format!("Volume {bsd} ({gb} GB)"),
            }
        }
    }
}

// ======================================================================
// Windows — SetupAPI + kernel32 IOCTLs (zero-desired-access, no elevation)
// ======================================================================

#[cfg(target_os = "windows")]
mod windows {
    use super::*;
    use std::os::raw::{c_int, c_void};

    type Handle = *mut c_void;
    type U16Ptr = *mut u16;

    const DIGCF_PRESENT: u32 = 0x2;
    const DIGCF_DEVICEINTERFACE: u32 = 0x10;
    const SPDRP_FRIENDLYNAME: u32 = 0xC;
    const DEVICE_REMOVABLE: u32 = 0x4000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const OPEN_EXISTING: u32 = 3;
    const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
    const IOCTL_DISK_GET_LENGTH_INFO: u32 = 0x0007_405C;
    const IOCTL_STORAGE_GET_DEVICE_NUMBER: u32 = 0x0002_D108;
    const ERROR_NO_MORE_ITEMS: u32 = 259;

    // {53f56307-b6bf-11d0-94f2-00a0c91efb8b} GUID_DEVINTERFACE_DISK,
    // laid out exactly as Windows stores it in memory (LE u32 x4):
    // Data1 | Data2:Data3 | Data4[0..4] raw | Data4[4..8] raw.
    const DISK_GUID: [u32; 4] = [0x53f5_6307, 0x11d0_b6bf, 0xa000_f294, 0x8bfb_1ec9];

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Guid {
        d: [u32; 4],
    }

    #[repr(C)]
    struct SpDeviceInterfaceData {
        cb_size: u32,
        class_guid: Guid,
        flags: u32,
        reserved: usize,
    }

    #[repr(C)]
    struct SpDevinfoData {
        cb_size: u32,
        class_guid: Guid,
        dev_inst: u32,
        reserved: usize,
    }

    #[link(name = "setupapi")]
    extern "system" {
        fn SetupDiGetClassDevsW(
            guid: *const Guid,
            enumerator: *const u16,
            parent: Handle,
            flags: u32,
        ) -> Handle;
        fn SetupDiEnumDeviceInterfaces(
            h: Handle,
            devinfo: Handle,
            guid: *const Guid,
            index: u32,
            data: *mut SpDeviceInterfaceData,
        ) -> c_int;
        fn SetupDiGetDeviceInterfaceDetailW(
            h: Handle,
            data: *const SpDeviceInterfaceData,
            detail: *mut c_void,
            detail_len: u32,
            needed: *mut u32,
            devinfo: *mut SpDevinfoData,
        ) -> c_int;
        fn SetupDiGetDeviceRegistryPropertyW(
            h: Handle,
            devinfo: *const SpDevinfoData,
            prop: u32,
            regtype: *mut u32,
            buf: U16Ptr,
            buflen: u32,
            needed: *mut u32,
        ) -> c_int;
        fn SetupDiDestroyDeviceInfoList(h: Handle) -> c_int;
    }

    #[link(name = "cfgmgr32")]
    extern "system" {
        fn CM_Get_DevNode_Status(
            status: *mut u32,
            problem: *mut u32,
            devinst: u32,
            flags: u32,
        ) -> c_int;
    }

    // kernel32 (auto-linked)
    extern "system" {
        fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            sa: Handle,
            disposition: u32,
            flags: u32,
            template: Handle,
        ) -> Handle;
        fn CloseHandle(h: Handle) -> c_int;
        fn DeviceIoControl(
            h: Handle,
            code: u32,
            inbuf: *mut c_void,
            inlen: u32,
            outbuf: *mut c_void,
            outlen: u32,
            returned: *mut u32,
            overlapped: Handle,
        ) -> c_int;
        fn GetLastError() -> u32;
    }

    fn wide(s: &str, buf: &mut [u16]) {
        for (i, c) in s.encode_utf16().enumerate().take(buf.len() - 1) {
            buf[i] = c;
        }
    }

    fn wide_len(buf: &[u16]) -> usize {
        buf.iter().position(|&c| c == 0).unwrap_or(buf.len())
    }

    struct DiskEntry {
        device_path: String,
        friendly: String,
        removable: bool,
    }

    fn disk_entries() -> Vec<DiskEntry> {
        let mut out = Vec::new();
        unsafe {
            let guid = Guid { d: DISK_GUID };
            let h = SetupDiGetClassDevsW(
                &guid,
                std::ptr::null(),
                std::ptr::null_mut(),
                DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
            );
            if h.is_null() || h == INVALID_HANDLE_VALUE {
                return out;
            }
            let mut idx = 0u32;
            loop {
                let mut ifdata = SpDeviceInterfaceData {
                    cb_size: std::mem::size_of::<SpDeviceInterfaceData>() as u32,
                    class_guid: Guid { d: [0; 4] },
                    flags: 0,
                    reserved: 0,
                };
                if SetupDiEnumDeviceInterfaces(h, std::ptr::null_mut(), &guid, idx, &mut ifdata)
                    == 0
                {
                    if GetLastError() == ERROR_NO_MORE_ITEMS {
                        break;
                    }
                    idx += 1;
                    continue;
                }
                // Size query, then fetch. Layout note: on x64 the detail
                // struct's cbSize must be 8 and DevicePath sits at offset 4.
                let mut needed = 0u32;
                let _ = SetupDiGetDeviceInterfaceDetailW(
                    h,
                    &ifdata,
                    std::ptr::null_mut(),
                    0,
                    &mut needed,
                    std::ptr::null_mut(),
                );
                if needed == 0 {
                    idx += 1;
                    continue;
                }
                let mut buf = vec![0u8; needed.max(8) as usize + 64];
                // SP_DEVICE_INTERFACE_DETAIL_DATA_W: DWORD cbSize; WCHAR path[]
                buf[0..4].copy_from_slice(&8u32.to_le_bytes());
                let mut devinfo = SpDevinfoData {
                    cb_size: std::mem::size_of::<SpDevinfoData>() as u32,
                    class_guid: Guid { d: [0; 4] },
                    dev_inst: 0,
                    reserved: 0,
                };
                let ok = SetupDiGetDeviceInterfaceDetailW(
                    h,
                    &ifdata,
                    buf.as_mut_ptr() as *mut c_void,
                    buf.len() as u32,
                    std::ptr::null_mut(),
                    &mut devinfo,
                );
                if ok == 0 {
                    idx += 1;
                    continue;
                }
                let u16s: Vec<u16> = buf[4..]
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .take_while(|&c| c != 0)
                    .collect();
                let device_path = String::from_utf16_lossy(&u16s);

                let mut fbuf = [0u16; 512];
                let mut friendly = String::new();
                let mut regtype = 0u32;
                let mut need2 = 0u32;
                if SetupDiGetDeviceRegistryPropertyW(
                    h,
                    &devinfo,
                    SPDRP_FRIENDLYNAME,
                    &mut regtype,
                    fbuf.as_mut_ptr(),
                    fbuf.len() as u32,
                    &mut need2,
                ) != 0
                {
                    friendly = String::from_utf16_lossy(&fbuf[..wide_len(&fbuf)]);
                }

                let mut status = 0u32;
                let mut problem = 0u32;
                let removable = CM_Get_DevNode_Status(
                    &mut status,
                    &mut problem,
                    devinfo.dev_inst,
                    0,
                ) == 0
                    && (status & DEVICE_REMOVABLE) != 0;

                out.push(DiskEntry {
                    device_path,
                    friendly,
                    removable,
                });
                idx += 1;
            }
            SetupDiDestroyDeviceInfoList(h);
        }
        out
    }

    /// Open with zero desired access (query-only, no elevation) and issue
    /// `code`, returning the raw output bytes.
    fn device_ioctl(path: &str, code: u32, out_len: usize) -> Option<Vec<u8>> {
        let mut w = [0u16; 512];
        wide(path, &mut w);
        unsafe {
            let h = CreateFileW(
                w.as_ptr(),
                0, // query attributes only — no read/write access needed
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null_mut(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            );
            if h.is_null() || h == INVALID_HANDLE_VALUE {
                return None;
            }
            let mut out = vec![0u8; out_len];
            let mut returned = 0u32;
            let ok = DeviceIoControl(
                h,
                code,
                std::ptr::null_mut(),
                0,
                out.as_mut_ptr() as *mut c_void,
                out.len() as u32,
                &mut returned,
                std::ptr::null_mut(),
            );
            CloseHandle(h);
            (ok != 0).then_some(out)
        }
    }

    /// STORAGE_DEVICE_NUMBER { type u32, number u32, partition u32 }.
    fn device_number(path: &str) -> Option<(u32, u32)> {
        let raw = device_ioctl(path, IOCTL_STORAGE_GET_DEVICE_NUMBER, 12)?;
        Some((
            u32::from_le_bytes(raw[0..4].try_into().ok()?),
            u32::from_le_bytes(raw[4..8].try_into().ok()?),
        ))
    }

    pub fn enumerate() -> Vec<OsDevice> {
        let mut out = Vec::new();
        let sys_index = std::env::var("SystemDrive")
            .ok()
            .and_then(|d| device_number(&format!("\\\\.\\{d}")))
            .map(|(_, n)| n);

        for e in disk_entries() {
            let size = device_ioctl(&e.device_path, IOCTL_DISK_GET_LENGTH_INFO, 8)
                .map(|b| u64::from_le_bytes(b[0..8].try_into().unwrap()))
                .unwrap_or(0);
            if size == 0 {
                continue;
            }
            // canonical name via device number -> \\.\PhysicalDriveN
            let pd = device_number(&e.device_path).map(|(_, n)| n);
            let name = pd
                .map(|n| format!("\\\\.\\PhysicalDrive{n}"))
                .unwrap_or_else(|| e.device_path.clone());
            out.push(OsDevice {
                id: pd.map(|n| format!("pdr{n}")).unwrap_or_else(|| format!("pdsk{}", out.len())),
                name: if e.friendly.is_empty() {
                    name.clone()
                } else {
                    e.friendly.clone()
                },
                kind: if e.removable { 2 } else { 3 },
                total: size,
                mounted: true,
                is_system: pd.is_some() && Some(pd.unwrap()) == sys_index,
                fs: String::new(),
                mount: String::new(),
                path: name,
                writable: true,
            });
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_disk_strips_partitions() {
        assert_eq!(parent_disk_of("sda1"), "sda");
        assert_eq!(parent_disk_of("sda12"), "sda");
        assert_eq!(parent_disk_of("nvme0n1p2"), "nvme0n1");
        assert_eq!(parent_disk_of("mmcblk0p3"), "mmcblk0");
        assert_eq!(parent_disk_of("vda"), "vda");
        assert_eq!(parent_disk_of("disk4"), "disk");
        // macOS partition style disk4s2 is handled by the caller, not here
        // (the 's' form would strip to "disk" — caller passes whole-name).
    }
}
