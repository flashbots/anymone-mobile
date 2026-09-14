{
  description = "Mobile development environment for anymone-mobile";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { nixpkgs, ... }:
    let
      # Build hosts supported by both nixpkgs and the Android NDK.
      systems = [ "x86_64-linux" "aarch64-darwin" ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          # On macOS, use the compiler from the selected Xcode installation.
          mkShell = if pkgs.stdenv.hostPlatform.isDarwin then pkgs.mkShellNoCC else pkgs.mkShell;
          ndkVersion = "26.3.11579264"; # r26d, matching CI.
          buildToolsVersion = "34.0.0"; # Default for AGP 8.5.2.
          android = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "35" ];
            buildToolsVersions = [ buildToolsVersion ];
            includeNDK = true;
            ndkVersions = [ ndkVersion ];
            includeEmulator = false;
            includeSystemImages = false;
          };
          androidHome = "${android.androidsdk}/libexec/android-sdk";
          gradle = pkgs.gradle-packages.mkGradle {
            version = "8.9";
            hash = "sha256-1yXXB7+r1N/clYxiQAOzyArMwD9wN7USLEsdDvFc7Ks=";
            defaultJava = pkgs.jdk17;
          };
        in
        {
          default = mkShell {
            packages = [
              pkgs.jdk17
              gradle
              android.androidsdk
              pkgs.rustup
              pkgs.cargo-ndk
            ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.xcodegen
            ];

            JAVA_HOME = pkgs.jdk17.home;
            ANDROID_HOME = androidHome;
            ANDROID_SDK_ROOT = androidHome;
            ANDROID_NDK_HOME = "${androidHome}/ndk/${ndkVersion}";

            # Maven's aapt2 binary cannot run directly on NixOS.
            shellHook = ''
              export GRADLE_OPTS="''${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${buildToolsVersion}/aapt2"
            '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
              # Nix's macOS SDK lacks iOS SDKs. Let xcrun use xcode-select,
              # while preserving explicit paths to a user-selected Xcode.
              case "''${DEVELOPER_DIR:-}" in /nix/store/*) unset DEVELOPER_DIR ;; esac
              case "''${SDKROOT:-}" in /nix/store/*) unset SDKROOT ;; esac
            '';
          };
        });
    };
}
