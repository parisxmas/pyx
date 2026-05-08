const std = @import("std");
const Io = std.Io;
const pyx = @import("pyx");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.print("pyx v0 — page_size={d}\n", .{pyx.page_size});
    try out.flush();
}
