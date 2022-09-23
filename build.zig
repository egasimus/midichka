const std = @import("std");

const flags = [_][]const u8{};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("midichka", "midichka.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkSystemLibrary("asound");
    exe.linkLibC();
    exe.addIncludeDir("portmidi-c/porttime");
    exe.addIncludeDir("portmidi-c/pm_common");
    exe.addIncludeDir("portmidi-zig/src/include");
    exe.addIncludeDir("porttime-zig/src/include");
    exe.addCSourceFile("portmidi-c/porttime/ptlinux.c", &flags);
    exe.addCSourceFile("portmidi-c/pm_common/pmutil.c", &flags);
    exe.addCSourceFile("portmidi-c/pm_common/portmidi.c", &flags);
    exe.defineCMacroRaw("PMALSA");
    exe.addCSourceFile("portmidi-c/pm_linux/pmlinux.c", &flags);
    exe.addCSourceFile("portmidi-c/pm_linux/pmlinuxalsa.c", &flags);
    exe.addCSourceFile("portmidi-c/pm_linux/finddefault.c", &flags);
    exe.install();
}

// zig build --search-prefix /nix/store/vr87ssak6xikg50z436x1zmd4ylm9bdb-alsa-lib-1.2.7.2/ --search-prefix /nix/store/6m2qx7wai768jcqmkpfz5qnv375411zq-alsa-lib-1.2.7.2-dev/
