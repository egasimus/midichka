const std = @import("std");
const spoon = @import("./spoon/import.zig");
const Term = spoon.Term;
const MIDI = @import("./midichka-midi.zig");

const Focus = enum { Inputs, Outputs, Routing, Mapper };

const inputLabels = [_][1]u8{
    .{'1'}, .{'2'}, .{'3'}, .{'4'},
    .{'5'}, .{'6'}, .{'7'}, .{'8'},
};

const outputLabels = [_][1]u8{
    .{'A'}, .{'B'}, .{'C'}, .{'D'},
    .{'E'}, .{'F'}, .{'G'}, .{'H'},
};

var buf: [100]u8 = undefined;

fn print(comptime fmt: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    return try std.fmt.bufPrint(buf[0..], fmt, args);
}

const Self = @This();

run:    bool,

midi:   *MIDI,

term:   *Term,

rc:     *Term.RenderContext,

in:     *const spoon.Input,

focus:  Focus,

input:  usize,

output: usize,

updated: std.os.pollfd,

pub fn init(self: *Self, midi: *MIDI) !*void {
    const term = undefined;
    self.* = .{
        .run = true,
        .midi = midi,
        .term = term,
        .rc = undefined,
        .in = undefined,
        .focus = Focus.Routing,
        .input = 0,
        .output = 0,
        .updated = .{
            .fd = self.term.tty.handle,
            .events = std.os.POLL.IN,
            .revents = undefined,
        },
    };
    try self.term.init();
    try self.term.uncook(.{});
    try self.term.fetchSize();
    try self.term.setWindowTitle("MIDIchka", .{});
    defer self.rc.done() catch {};
}

pub fn deinit(self: *Self) void {
    self.term.cook() catch {};
    self.term.deinit();
}

pub fn render(self: *Self) !void {
    self.rc = &try self.term.getRenderContext();
    defer self.rc.done() catch {};
    try self.rc.clear();
    if (self.term.width < 80) return try self.render_terminal_too_small();
    try self.write(1, 2, 80, "[F1] Help  [F2] New   [F3] Save  [F4] Load   [F5] Refresh", false);
    try self.render_inputs(3, 2);
    try self.render_outputs(6 + self.midi.inputs.items.len, 2);
    try self.render_matrix(3, 34);
    try self.render_mapper(3, 57);
}

fn render_terminal_too_small(self: *Self) !void {
    try self.rc.setAttribute(.{ .fg = .red, .bold = true });
    try self.rc.writeAllWrapping("Terminal too small!");
}

fn write(self: *Self, row: usize, col: usize, width: usize, text: []const u8, sel: bool) !void {
    try self.rc.moveCursorTo(row, col);
    var attr = .{ .fg = spoon.Attribute.Colour.bright_white, .reverse = sel };
    try self.rc.setAttribute(attr);
    var rpw = self.rc.restrictedPaddingWriter(width);
    try rpw.writer().writeAll(text);
    try rpw.pad();
}

fn render_inputs(self: *Self, row: usize, col: usize) !void {
    try self.write(row, col, 30, "[F6] Inputs", self.focus == Focus.Inputs);
    for (self.midi.inputs.items) |input, i| {
        const args = .{ inputLabels[i], input.id, input.name };
        const name = try print(" {s} (id {}) {s}   [ ] [ ]", args);
        try self.write(row + i + 1, col, 30, name, self.input == i);
    }
}

fn render_outputs(self: *Self, row: usize, col: usize) !void {
    try self.write(row, col, 30, "[F7] Outputs", self.focus == Focus.Outputs);
    for (self.midi.outputs.items) |output, o| {
        const args = .{ outputLabels[o], output.id, output.name };
        const name = try print(" {s} (id {}) {s}   [ ] [ ]", args);
        try self.write(row + o + 1, col, 30, name, self.output == o);
    }
}

fn render_matrix(self: *Self, row: usize, col: usize) !void {
    try self.write(row, col, 21, "[F8] Routing", self.focus == Focus.Routing);
    var fbuf: [4]u8 = undefined;
    for (self.midi.inputs.items) |_, i| {
        const r0 = 2 + row;
        const c = 1 + col + 5 * (i + 1);
        const w = 5;
        try self.write(r0, c, w, try std.fmt.bufPrint(fbuf[0..], "  {s} ", .{inputLabels[i]}), self.input == i);
        for (self.midi.outputs.items) |_, o| {
            const r = 2 * (o + 1);
            try self.write(r0 + r, c, w, " [ ]", self.input == i and self.output == o);
        }
    }
    for (self.midi.outputs.items) |_, o| {
        try self.write(2 + row + 2 * (o + 1), col, 5, try std.fmt.bufPrint(fbuf[0..], "  {s}", .{outputLabels[o]}), self.output == o);
    }
    for (self.midi.routes.items) |routing| {
        try self.write(2 + row + 2 * (routing.output + 1), 1 + col + 5 * (routing.input + 1), 5, " [x]", self.input == routing.input and self.output == routing.output);
    }
}

fn render_mapper(self: *Self, row: usize, col: usize) !void {
    try self.write(row, col, 50, "[F9] Filter/Remap", self.focus == Focus.Mapper);
    try self.write(row + 2, col, 50, " In   Event Data1 Data2 -> Out   Event Data1 Data2", false);
    var r: usize = 0;
    for (self.midi.routes.items) |routing| {
        var i = routing.input;
        var o = routing.output;
        const table_row = try print(" {s}      *     *     *       {s}      *     *     *  ", .{ inputLabels[i], outputLabels[o] });
        const selected = self.input == i and self.output == o;
        try self.write(row + 4 + r * 2, col, 50, table_row, selected);
        r = r + 1;
    }
}

pub fn handle(self: *Self) !void {
    var rbuf: [16]u8 = undefined;
    var read = try self.term.readInput(&rbuf);
    var it = spoon.inputParser(rbuf[0..read]);
    while (it.next()) |in| {
        self.in = &in;
        if (self.on_exit()) {
            self.run = false;
            break;
        }
        if (self.on_section() or
            self.on_port() or
            try self.on_toggle())
        {
            try self.render();
            continue;
        }
    }
}

fn on_exit(self: *Self) bool {
    const in = self.in;
    return (in.eqlDescription("escape") or
        in.eqlDescription("q") or
        in.eqlDescription("F10"));
}

fn on_section(self: *Self) bool {
    const in = self.in;
    if (in.eqlDescription("F6")) {
        self.focus = Focus.Inputs;
        return true;
    }
    if (in.eqlDescription("F7")) {
        self.focus = Focus.Outputs;
        return true;
    }
    if (in.eqlDescription("F8")) {
        self.focus = Focus.Routing;
        return true;
    }
    if (in.eqlDescription("F9")) {
        self.focus = Focus.Mapper;
        return true;
    }
    return false;
}

fn on_port(self: *Self) bool {
    const in = self.in;
    if (in.eqlDescription("h") or in.eqlDescription("arrow-left")) {
        if (self.input <= 0) {
            self.input = self.midi.inputs.items.len - 1;
        } else {
            self.input = self.input - 1;
        }
        return true;
    }
    if (in.eqlDescription("l") or in.eqlDescription("arrow-right")) {
        if (self.input >= self.midi.inputs.items.len - 1) {
            self.input = 0;
        } else {
            self.input = self.input + 1;
        }
        return true;
    }
    if (in.eqlDescription("k") or in.eqlDescription("arrow-up")) {
        if (self.output <= 0) {
            self.output = self.midi.outputs.items.len - 1;
        } else {
            self.output = self.output - 1;
        }
        return true;
    }
    if (in.eqlDescription("j") or in.eqlDescription("arrow-down")) {
        if (self.output >= self.midi.outputs.items.len - 1) {
            self.output = 0;
        } else {
            self.output = self.output + 1;
        }
        return true;
    }
    return false;
}

fn on_toggle(self: *Self) !bool {
    const in = self.in;
    if (in.eqlDescription("space") or in.eqlDescription("enter")) {
        try self.midi.toggle(self.input, self.output);
        return true;
    }
    return false;
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

fn portName() !void {}

fn portInputIndicator() !void {}

fn portOutputIndicator() !void {}

fn portList() !void {}

fn portMatrix() !void {}

fn portMatrixRow() !void {}

fn portMatrixColumn() !void {}
