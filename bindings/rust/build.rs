//! Link `libgist` + `libirgx` — only under the opt-in `native` feature.
//! The default crate is a pure subprocess transport and this script is a
//! no-op; with `--features native` it resolves the libraries beside the
//! checkout (`<repo>/zig-out/lib`) or at `$GIST_LIB_DIR`, links both, and
//! burns an rpath so the test/host binary finds them at run time without
//! `DYLD_LIBRARY_PATH`.
//!
//! `libgist` owns the session / exact / analytic-producer symbols; `libirgx`
//! owns the substrate (status, fault, row cursor, schema digest). A host that
//! links only one of them is incomplete.

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=GIST_LIB_DIR");
    if std::env::var_os("CARGO_FEATURE_NATIVE").is_none() {
        return; // subprocess-only build — nothing native to link
    }
    let dir = resolve_lib_dir().unwrap_or_else(|| {
        panic!(
            "feature `native` needs libgist + libirgx; build them with \
             `zig build` in the gist checkout (or set $GIST_LIB_DIR to the dir \
             holding libgist.{{dylib,so}} and libirgx.{{dylib,so}})"
        )
    });
    let dir = dir.display();
    println!("cargo:rustc-link-search=native={dir}");
    println!("cargo:rustc-link-lib=dylib=gist");
    println!("cargo:rustc-link-lib=dylib=irgx");
    // rpath so the dylibs resolve at run time (macOS + ELF).
    println!("cargo:rustc-link-arg=-Wl,-rpath,{dir}");
}

/// The directory holding both product + substrate dylibs: `$GIST_LIB_DIR` if
/// set, else the checkout's `zig-out/lib` found by walking up from the crate.
fn resolve_lib_dir() -> Option<PathBuf> {
    if let Some(env) = std::env::var_os("GIST_LIB_DIR") {
        let dir = PathBuf::from(env);
        return has_libs(&dir).then_some(dir);
    }
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR")?);
    manifest.ancestors().find_map(|root| {
        let dir = root.join("zig-out").join("lib");
        (root.join("build.zig").is_file() && has_libs(&dir)).then_some(dir)
    })
}

fn has_libs(dir: &Path) -> bool {
    let gist = dir.join("libgist.dylib").is_file() || dir.join("libgist.so").is_file();
    let eng = dir.join("libirgx.dylib").is_file() || dir.join("libirgx.so").is_file();
    gist && eng
}
