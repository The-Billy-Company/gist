//! Link the self-contained `libirregex` shared library — only under the opt-in
//! `native` feature (ADR-352). The default crate is a pure subprocess transport
//! and this script is a no-op; with `--features native` it resolves the library
//! beside the kernel (`<repo>/pkg/kernels/irregex/zig-out/lib`) or at
//! `$GIST_LIB_DIR`, links it, and burns an rpath so the test/host binary finds it
//! at run time without `DYLD_LIBRARY_PATH`.

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=GIST_LIB_DIR");
    if std::env::var_os("CARGO_FEATURE_NATIVE").is_none() {
        return; // subprocess-only build — nothing native to link
    }
    let dir = resolve_lib_dir().unwrap_or_else(|| {
        panic!(
            "feature `native` needs libirregex; build it with `make install-gist` \
             (or set $GIST_LIB_DIR to the dir holding libirregex.{{dylib,so}})"
        )
    });
    let dir = dir.display();
    println!("cargo:rustc-link-search=native={dir}");
    println!("cargo:rustc-link-lib=dylib=irregex");
    // rpath so the dylib resolves at run time (macOS + ELF).
    println!("cargo:rustc-link-arg=-Wl,-rpath,{dir}");
}

/// The directory holding `libirregex.{dylib,so}`: `$GIST_LIB_DIR` if set, else the
/// kernel's `zig-out/lib` found by walking up from the crate to the `build.zig` root.
fn resolve_lib_dir() -> Option<PathBuf> {
    if let Some(env) = std::env::var_os("GIST_LIB_DIR") {
        let dir = PathBuf::from(env);
        return has_lib(&dir).then_some(dir);
    }
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR")?);
    manifest.ancestors().find_map(|root| {
        let dir = root.join("zig-out").join("lib");
        (root.join("build.zig").is_file() && has_lib(&dir)).then_some(dir)
    })
}

fn has_lib(dir: &Path) -> bool {
    dir.join("libirregex.dylib").is_file() || dir.join("libirregex.so").is_file()
}
