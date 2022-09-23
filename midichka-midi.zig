const std = @import("std");
const pm  = @import("./portmidi-zig/src/portmidi.zig");
const pt  = @import("./porttime-zig/src/porttime.zig");
pub const Input  = struct { id: pm.DeviceID, name: []u8, stream: ?*pm.Stream = null };
pub const Output = struct { id: pm.DeviceID, name: []u8, stream: ?*pm.Stream = null };
pub const Route  = struct { input: usize, output: usize };
pub const MIDI   = struct {
    inputs:  std.ArrayList(Input),
    outputs: std.ArrayList(Output),
    routes:  std.ArrayList(Route),
    monitor: ?pm.Queue,
    updated: std.os.pollfd,

    pub fn init(allocator: std.mem.Allocator) !MIDI {
        var self: MIDI = .{
            .inputs      = std.ArrayList(Input).init(allocator),
            .outputs     = std.ArrayList(Output).init(allocator),
            .routes      = std.ArrayList(Route).init(allocator),
            .monitor     = pm.createQueue(32, @sizeOf(i32)),
            .updated     = .{
                .fd      = try std.os.eventfd(0, 0),
                .events  = std.os.POLL.IN,
                .revents = undefined,
            }
        };
        try self.scan();
        const resolution = 1;
        const callback   = @ptrCast(pt.Callback, process);
        const selfPtr    = @ptrCast(?*anyopaque, &self);
        try pt.start(resolution, callback, selfPtr);
        return self;
    }

    pub fn deinit(self: *MIDI) void {
        self.inputs.deinit();
        self.outputs.deinit();
        self.routes.deinit();
    }

    pub fn scan(self: *MIDI) !void {
        const stdout = std.io.getStdOut().writer();
        pm.initialize();
        try stdout.print("PortMidi initialized.\n", .{});

        const deviceCount = pm.countDevices();
        const timeProc: ?pm.TimeProcPtr = null;
        try stdout.print("{} devices found.\n", .{deviceCount});

        var buf: [100]u8 = undefined;
        var i: pm.DeviceID = 0;
        while (i < deviceCount) {
            const device_info = pm.getDeviceInfo(i) orelse continue;
            if (device_info.input) {
                try stdout.print("{} In:  {s}\n", .{ i, device_info.name });
                const name = try std.fmt.bufPrint(buf[0..], "{s}", .{device_info.name});
                var stream: ?*anyopaque = undefined;
                try pm.openInput(&stream, i, null, 0, timeProc, null);
                try self.inputs.append(.{ .id = i, .name = name, .stream = stream });
            }
            if (device_info.output) {
                try stdout.print("{} Out: {s}\n", .{ i, device_info.name });
                const name = try std.fmt.bufPrint(buf[0..], "{s}", .{device_info.name});
                var stream: ?*anyopaque = undefined;
                try pm.openOutput(&stream, i, null, 0, timeProc, null, 0);
                try self.outputs.append(.{ .id = i, .name = name, .stream = stream });
            }
            i = i + 1;
        }
    }

    pub fn toggle(self: *MIDI, input: usize, output: usize) !void {
        var exists: bool = false;
        for (self.routes.items) |routing| {
            if (routing.input == input and routing.output == output) {
                exists = true;
                break;
            }
        }
        if (exists) {
            for (self.routes.items) |routing, r| {
                if (routing.input == input and routing.output == output) {
                    _ = self.routes.orderedRemove(r);
                    break;
                }
            }
        } else {
            try self.routes.append(.{ .input = input, .output = output });
        }
    }
};

pub fn process(_: i32, self: *MIDI) callconv(.C) void {
    var buffer: pm.Event = undefined;
    var updated = false;
    const queue = self.monitor;
    for (self.inputs.items) |input| {
        const stream = input.stream orelse continue;
        var result = pm.read(stream, &buffer, 1) catch continue;
        while (result > 0) {
            updated = true;
            const message = @ptrCast(*anyopaque, &buffer.message);
            pm.enqueue(queue.?, message) catch continue;
            result = pm.read(stream, &buffer, 1) catch break;
        }
    }
    if (updated) {
        _ = std.os.write(self.updated.fd, &.{0}) catch return;
    }
}
