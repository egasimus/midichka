const std = @import("std");

const MIDI = @import("./midichka-midi.zig").MIDI;
var midi: MIDI = undefined;

const TUI = @import("./midichka-tui.zig").TUI;
var tui: TUI = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};      defer std.debug.assert(!gpa.deinit());
    var aa = std.heap.ArenaAllocator.init(gpa.allocator()); defer aa.deinit();
    const allocator = aa.allocator();
    midi = try MIDI.init(allocator); defer midi.deinit();
    tui  = try TUI.init(midi);       defer tui.deinit();
    //std.os.sigaction(std.os.SIG.WINCH, &std.os.Sigaction{
        //.handler = .{ .handler = winch }, .mask = std.os.empty_sigset, .flags = 0,
    //}, null);
    //var updated: [2]std.os.pollfd = .{ tui.updated, midi.updated };
    //try tui.render();
    //while (tui.run) {
        //_ = try std.os.poll(&updated, -1);
        //try tui.handle();
    //}
}

fn winch(_: c_int) callconv(.C) void {
    tui.term.fetchSize() catch {};
    tui.render() catch {};
}

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    @setCold(true);
    tui.term.cook() catch {};
    std.builtin.default_panic(msg, trace);
}
