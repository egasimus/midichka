const std = @import("std");
const pm = @import("./portmidi-zig/src/portmidi.zig");
const pt = @import("./porttime-zig/src/porttime.zig");
const spoon = @import("./spoon/import.zig");

pub var routings: std.ArrayList(Routing) = undefined;

const os = std.os;
const fmt = std.fmt;

var term: spoon.Term = undefined;
var run: bool = true;

var activeInput: usize = 0;
var activeOutput: usize = 0;
var activeSection: Section = Section.routing;
const Section = enum { inputs, outputs, routing, mapper };

var inputs: std.ArrayList(Input) = undefined;
var outputs: std.ArrayList(Output) = undefined;

const inputLabels = [_][1]u8{
    .{'1'}, .{'2'}, .{'3'}, .{'4'},
    .{'5'}, .{'6'}, .{'7'}, .{'8'},
};

const outputLabels = [_][1]u8{
    .{'A'}, .{'B'}, .{'C'}, .{'D'},
    .{'E'}, .{'F'}, .{'G'}, .{'H'},
};

var active: bool = false;

var monitor: pm.Queue = undefined;

pub const Input = struct { id: pm.DeviceID, name: []u8, stream: ?*pm.Stream = null };

pub const Output = struct { id: pm.DeviceID, name: []u8, stream: ?*pm.Stream = null };

pub const Routing = struct {
    input: usize,
    output: usize,
};

var midiFd: os.pollfd = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var aa = std.heap.ArenaAllocator.init(gpa.allocator());
    defer aa.deinit();
    const allocator = aa.allocator();
    inputs = std.ArrayList(Input).init(allocator);
    defer inputs.deinit();
    outputs = std.ArrayList(Output).init(allocator);
    defer outputs.deinit();
    routings = std.ArrayList(Routing).init(allocator);
    defer routings.deinit();
    pm.initialize();
    const stdout = std.io.getStdOut().writer();
    const d = pm.countDevices();
    const timeProc: ?pm.TimeProcPtr = null;
    var i: pm.DeviceID = 0;
    try stdout.print("{} devices found.\n", .{d});
    while (i < d) {
        const device_info = pm.getDeviceInfo(i) orelse continue;
        if (device_info.input) {
            try stdout.print("{} In:  {s}\n", .{ i, device_info.name });
            const name = try std.fmt.allocPrint(allocator, "{s}", .{device_info.name});
            var stream: ?*anyopaque = undefined;
            try pm.openInput(&stream, i, null, 0, timeProc, null);
            try inputs.append(.{ .id = i, .name = name, .stream = stream });
        }
        if (device_info.output) {
            try stdout.print("{} Out: {s}\n", .{ i, device_info.name });
            const name = try std.fmt.allocPrint(allocator, "{s}", .{device_info.name});
            var stream: ?*anyopaque = undefined;
            try pm.openOutput(&stream, i, null, 0, timeProc, null, 0);
            try outputs.append(.{ .id = i, .name = name, .stream = stream });
        }
        i = i + 1;
    }
    monitor = pm.createQueue(32, @sizeOf(i32)) orelse return;
    midiFd = .{
        .fd = try os.eventfd(0, 0),
        .events = os.POLL.IN,
        .revents = undefined,
    };
    try pt.start(1, processEvents, &routings);
    active = true;
    try term.init();
    defer term.deinit();
    os.sigaction(os.SIG.WINCH, &os.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);
    var fds: [2]os.pollfd = undefined;
    fds[0] = .{
        .fd = term.tty.handle,
        .events = os.POLL.IN,
        .revents = undefined,
    };
    fds[1] = midiFd;
    try term.uncook(.{});
    defer term.cook() catch {};
    try term.fetchSize();
    try term.setWindowTitle("MIDIchka", .{});
    try render();
    var buf: [16]u8 = undefined;
    //var msg: pm.Event = undefined;
    while (run) {
        _ = try os.poll(&fds, -1);
        const read = try term.readInput(&buf);
        var it = spoon.inputParser(buf[0..read]);
        while (it.next()) |in| {
            if (onExit(&in)) {
                run = false;
                break;
            }
            if (onSelectSection(&in) or onSelectPort(&in) or try onToggleConnection(&in)) {
                try render();
                continue;
            }
        }
    }
}

pub fn processEvents(_: i32, _: ?*anyopaque) callconv(.C) void {
    if (!active) return;
    var buffer: pm.Event = undefined;
    var updated = false;
    for (inputs.items) |input| {
        const stream = input.stream orelse continue;
        var result = pm.read(stream, &buffer, 1) catch continue;
        while (result > 0) {
            updated = true;
            pm.enqueue(monitor, @ptrCast(*anyopaque, &buffer.message)) catch continue;
            result = pm.read(stream, &buffer, 1) catch break;
        }
    }
    if (updated) {
        _ = os.write(midiFd.fd, &.{0}) catch return;
    }
}

fn onExit(in: *const spoon.Input) bool {
    return in.eqlDescription("escape") or in.eqlDescription("q") or in.eqlDescription("F10");
}

fn onSelectSection(in: *const spoon.Input) bool {
    if (in.eqlDescription("F6")) {
        activeSection = Section.inputs;
        return true;
    }
    if (in.eqlDescription("F7")) {
        activeSection = Section.outputs;
        return true;
    }
    if (in.eqlDescription("F8")) {
        activeSection = Section.routing;
        return true;
    }
    if (in.eqlDescription("F9")) {
        activeSection = Section.mapper;
        return true;
    }
    return false;
}

fn onSelectPort(
    in: *const spoon.Input,
) bool {
    if (in.eqlDescription("h") or in.eqlDescription("arrow-left")) {
        if (activeInput <= 0) {
            activeInput = inputs.items.len - 1;
        } else {
            activeInput = activeInput - 1;
        }
        return true;
    }
    if (in.eqlDescription("l") or in.eqlDescription("arrow-right")) {
        if (activeInput >= inputs.items.len - 1) {
            activeInput = 0;
        } else {
            activeInput = activeInput + 1;
        }
        return true;
    }
    if (in.eqlDescription("k") or in.eqlDescription("arrow-up")) {
        if (activeOutput <= 0) {
            activeOutput = outputs.items.len - 1;
        } else {
            activeOutput = activeOutput - 1;
        }
        return true;
    }
    if (in.eqlDescription("j") or in.eqlDescription("arrow-down")) {
        if (activeOutput >= outputs.items.len - 1) {
            activeOutput = 0;
        } else {
            activeOutput = activeOutput + 1;
        }
        return true;
    }
    return false;
}

fn onToggleConnection(in: *const spoon.Input) !bool {
    if (in.eqlDescription("space") or in.eqlDescription("enter")) {
        var exists: bool = false;
        for (routings.items) |routing| {
            if (routing.input == activeInput and routing.output == activeOutput) {
                exists = true;
                break;
            }
        }
        if (exists) {
            for (routings.items) |routing, r| {
                if (routing.input == activeInput and routing.output == activeOutput) {
                    _ = routings.orderedRemove(r);
                    break;
                }
            }
        } else {
            try routings.append(.{ .input = activeInput, .output = activeOutput });
        }
        return true;
    }
    return false;
}

fn render() !void {
    var rc = try term.getRenderContext();
    defer rc.done() catch {};

    try rc.clear();

    if (term.width < 80) {
        try rc.setAttribute(.{ .fg = .red, .bold = true });
        try rc.writeAllWrapping("Terminal too small!");
        return;
    }

    try label(&rc, 1, 2, 80, "[F1] Help  [F2] New   [F3] Save  [F4] Load   [F5] Refresh", false);
    try renderInputs(&rc, 3, 2);
    try renderOutputs(&rc, 6 + inputs.items.len, 2);
    try renderMatrix(&rc, 3, 34);
    try renderMapper(&rc, 3, 57);
}

fn renderInputs(rc: *spoon.Term.RenderContext, row: usize, col: usize) !void {
    try label(rc, row, col, 30, "[F6] Inputs", activeSection == Section.inputs);
    var buf: [100]u8 = undefined;
    for (inputs.items) |input, i| {
        const args = .{ inputLabels[i], input.id, input.name };
        const name = try fmt.bufPrint(buf[0..], " {s} (id {}) {s}   [ ] [ ]", args);
        try label(rc, row + i + 1, col, 30, name, activeInput == i);
    }
}

fn renderOutputs(rc: *spoon.Term.RenderContext, row: usize, col: usize) !void {
    try label(rc, row, col, 30, "[F7] Outputs", activeSection == Section.outputs);
    var buf: [100]u8 = undefined;
    for (outputs.items) |output, o| {
        const args = .{ outputLabels[o], output.id, output.name };
        const name = try fmt.bufPrint(buf[0..], " {s} (id {}) {s}   [ ] [ ]", args);
        try label(rc, row + o + 1, col, 30, name, activeOutput == o);
    }
}

fn renderMatrix(rc: *spoon.Term.RenderContext, row: usize, col: usize) !void {
    try label(rc, row, col, 21, "[F8] Routing", activeSection == Section.routing);
    var buf: [4]u8 = undefined;
    for (inputs.items) |_, i| {
        const r0 = 2 + row;
        const c = 1 + col + 5 * (i + 1);
        const w = 5;
        try label(rc, r0, c, w, try fmt.bufPrint(buf[0..], "  {s} ", .{inputLabels[i]}), activeInput == i);
        for (outputs.items) |_, o| {
            const r = 2 * (o + 1);
            try label(rc, r0 + r, c, w, " [ ]", activeInput == i and activeOutput == o);
        }
    }
    for (outputs.items) |_, o| {
        try label(rc, 2 + row + 2 * (o + 1), col, 5, try fmt.bufPrint(buf[0..], "  {s}", .{outputLabels[o]}), activeOutput == o);
    }
    for (routings.items) |routing| {
        try label(rc, 2 + row + 2 * (routing.output + 1), 1 + col + 5 * (routing.input + 1), 5, " [x]", activeInput == routing.input and activeOutput == routing.output);
    }
}

fn renderMapper(rc: *spoon.Term.RenderContext, row: usize, col: usize) !void {
    try label(rc, row, col, 50, "[F9] Filter/Remap", activeSection == Section.mapper);
    try label(rc, row + 2, col, 50, " In   Event Data1 Data2 -> Out   Event Data1 Data2", false);
    var r: usize = 0;
    var buf: [100]u8 = undefined;
    for (routings.items) |routing| {
        var i = routing.input;
        var o = routing.output;
        const table_row = try fmt.bufPrint(buf[0..], " {s}      *     *     *       {s}      *     *     *  ", .{ inputLabels[i], outputLabels[o] });
        const selected = activeInput == i and activeOutput == o;
        try label(rc, row + 4 + r * 2, col, 50, table_row, selected);
        r = r + 1;
    }
}
// filter/remap table:
//
//   NAME             PORT     EVENT  DATA1 DATA2 PORT      EVENT  DATA1 DATA2
//
//   Lo Kik           BeatStep ON C10    35     * -
//                                              + KickSynth ON C01    42    80
//
//   Hi Kik           BeatStep ON C10    36     * -
//                                              + KickSynth ON C01    42   110
//                                              + Sampler   ON C01    60    18
//
//   Lo Snare         BeatStep ON C10    38     * -
//                                              + Sampler   ON C02    40   100
//
//   Hi Snare         BeatStep ON C10    40     * -
//                                              + Sampler   ON C03    60    80
//
//   Open Hi-Hat      BeatStep ON C10    46     * Sampler   ON C04    71    *
//
//   Closed Hi-Hat    BeatStep ON C10    42     * Sampler   ON C04    70    *
//                                              + Sampler   OF C04    71    *

fn label(rc: *spoon.Term.RenderContext, row: usize, col: usize, width: usize, text: []const u8, selected: bool) !void {
    try rc.moveCursorTo(row, col);
    try rc.setAttribute(.{ .fg = spoon.Attribute.Colour.bright_white, .reverse = selected });
    var rpw = rc.restrictedPaddingWriter(width);
    try rpw.writer().writeAll(text);
    try rpw.pad();
}

fn portName() !void {}

fn portInputIndicator() !void {}

fn portOutputIndicator() !void {}

fn portList() !void {}

fn portMatrix() !void {}

fn portMatrixRow() !void {}

fn portMatrixColumn() !void {}

fn handleSigWinch(_: c_int) callconv(.C) void {
    term.fetchSize() catch {};
    render() catch {};
}

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    @setCold(true);
    term.cook() catch {};
    std.builtin.default_panic(msg, trace);
}
