const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;

const terminal = @import("../terminal.zig");
const Position = @import("../main.zig").Position;
const editor = @import("../editor.zig");
// In here the representation doesn't matter as much so we can use a type alias.
const Lines = ArrayList(ArrayList(u8));

pub const Cursor = struct {
    const Self = @This();

    position: Position = .{ .row = 0, .column = 0 },
    /// This is the column that the cursor will try to be on, if possible.
    /// You could also say this column wants to be the one that the cursor is on.
    ///
    /// Here is an example showcasing correct behavior of cursor movement,
    /// where `|` is the cursor:
    ///
    /// 1. Initial state:
    ///    ```
    ///    hello| world
    ///
    ///    ```
    /// 2. Pressing down key:
    ///    ```
    ///    hello world
    ///    |
    ///    ```
    /// 3. Pressing up key: back to 1.
    ///
    /// This effect is achieved using the ambitious column.
    ambitiousColumn: u16 = 0,

    /// An abstraction over the actual `terminal.cursor.setPosition` with an offset.
    fn setPositionWithOffset(self: Self, offset: Position) !void {
        try terminal.cursor.setPosition(.{
            .row = self.position.row + offset.row,
            .column = self.position.column + offset.column,
        });
    }

    pub fn draw(self: Self, lines: Lines, offset: Position) !void {
        try self.setPositionWithOffset(offset);
        try terminal.control.setBlackOnWhiteBackgroundCellColor();

        // Write the character that's below the cursor
        const current_line_chars = self.getCurrentLine(lines).items;
        if (self.position.column >= current_line_chars.len) {
            // If the index would be out of bounds, still draw the cursor
            try terminal.writeByte(' ');
        } else {
            try terminal.writeByte(current_line_chars[self.position.column]);
        }
        try terminal.control.resetForegroundAndBackgroundCellColor();
    }

    fn insert(self: *Self, lines: Lines, char: u8) !void {
        const current_line = self.getCurrentLine(lines);
        try current_line.insert(self.position.column, char);
        self.position.column += 1;
        self.setAmbitiousColumn();
    }

    fn insertSlice(self: *Self, lines: Lines, slice: []const u8) !void {
        const current_line = self.getCurrentLine(lines);
        try current_line.insertSlice(self.position.column, slice);
        self.position.column += @intCast(u16, slice.len);
        self.setAmbitiousColumn();
    }

    fn getCurrentLine(self: Self, lines: Lines) *ArrayList(u8) {
        return &lines.items[self.position.row];
    }

    /// Returns the index of character before the cursor, on the current line.
    ///
    /// If the cursor is at BOL, this returns `null`.
    fn getPreviousCharIndex(self: Self) ?u16 {
        if (self.position.column == 0) {
            // There is no character before this
            return null;
        } else {
            return self.position.column - 1;
        }
    }

    /// Returns the index of the character on the cursor, on the current line.
    ///
    /// If the cursor is at the EOL, this returns `null`.
    fn getCurrentCharIndex(self: Self, lines: Lines) ?u16 {
        const current_line_chars = self.getCurrentLine(lines).items;
        if (self.position.column == current_line_chars.len) {
            // There is no character before this
            return null;
        } else {
            return self.position.column;
        }
    }

    fn removeCurrentLineChar(self: Self, lines: Lines, index: u16) void {
        const current_line = self.getCurrentLine(lines);
        _ = current_line.orderedRemove(index);
    }

    /// Removes all consecutive spaces before the cursor
    /// and returns whether or not a space was removed.
    fn removePreviousSuccessiveSpaces(self: *Self, lines: Lines) bool {
        var space_removed = false;
        const current_line_chars = self.getCurrentLine(lines).items;
        while (self.getPreviousCharIndex()) |char_to_remove_index| {
            if (current_line_chars[char_to_remove_index] == ' ') {
                self.removeCurrentLineChar(lines, char_to_remove_index);
                self.position.column -= 1;
                space_removed = true;
                continue;
            } else {
                break;
            }
        }
        return space_removed;
    }

    fn tryToReachAmbitiousColumn(self: *Self, lines: Lines) void {
        const current_line_len = @intCast(u16, self.getCurrentLine(lines).items.len);
        if (current_line_len < self.ambitiousColumn) {
            // If the ambitious column is out of reach,
            // at least go to this line's end
            self.position.column = current_line_len;
        } else {
            self.position.column = self.ambitiousColumn;
        }
    }

    fn setAmbitiousColumn(self: *Self) void {
        self.ambitiousColumn = self.position.column;
    }

    fn goToLineEnd(self: *Self, line: ArrayList(u8)) void {
        self.position.column = @intCast(u16, line.items.len);
    }

    // TODO: Currently all blocks of successive non-space characters are treated as one "word".
    //       This could be improved to treat e.g. "hello.world" as 2 words instead of 1.

    fn goToNextLeftWholeWord(self: *Self, lines: Lines) void {
        const current_line_chars = self.getCurrentLine(lines).items;
        if (self.getPreviousCharIndex()) |current_char_index| {
            self.position.column -= 1;
            if (current_line_chars[current_char_index] == ' ') {
                // Go to the right until we hit a non-space or EOL
                while (self.getPreviousCharIndex()) |char_index| : (self.position.column -= 1)
                    if (current_line_chars[char_index] != ' ')
                        break;
            }
            // Go to the right until we hit a space or EOL
            while (self.getPreviousCharIndex()) |char_index| : (self.position.column -= 1)
                if (current_line_chars[char_index] == ' ')
                    break;
        } else if (self.position.row != 0) {
            self.position.row -= 1;
            self.goToLineEnd(self.getCurrentLine(lines).*);
            // Try again
            return self.goToNextLeftWholeWord(lines);
        }
        self.setAmbitiousColumn();
    }
    fn goToNextRightWholeWord(self: *Self, lines: Lines) void {
        const current_line_chars = self.getCurrentLine(lines).items;
        if (self.getCurrentCharIndex(lines)) |current_char_index| {
            self.position.column += 1;
            if (current_line_chars[current_char_index] == ' ') {
                // Go to the right until we hit a non-space or EOL
                while (self.getCurrentCharIndex(lines)) |char_index| : (self.position.column += 1)
                    if (current_line_chars[char_index] != ' ')
                        break;
            }
            // Go to the right until we hit a space or EOL
            while (self.getCurrentCharIndex(lines)) |char_index| : (self.position.column += 1)
                if (current_line_chars[char_index] == ' ')
                    break;
        } else if (self.position.row != lines.items.len - 1) {
            self.position.row += 1;
            self.position.column = 0;
            // Try again
            return self.goToNextRightWholeWord(lines);
        }
        self.setAmbitiousColumn();
    }

    pub fn handleKey(self: *Self, allocator: mem.Allocator, lines: *Lines, key: terminal.input.Key) !?editor.Action {
        switch (key) {
            .char => |char| try self.insert(lines.*, char),

            .up => {
                if (self.position.row == 0) {
                    // We are at BOF
                    self.position.column = 0;
                } else {
                    self.position.row -= 1;
                    self.tryToReachAmbitiousColumn(lines.*);
                }
            },
            .down => {
                if (self.position.row == lines.items.len - 1) {
                    // We are at EOF
                    const last_line_index = @intCast(u16, lines.items.len - 1);
                    const last_line = lines.items[last_line_index];
                    self.goToLineEnd(last_line);
                } else {
                    self.position.row += 1;
                    self.tryToReachAmbitiousColumn(lines.*);
                }
            },
            .left => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.column == 0) {
                            // Wrap back to the previous line's end if we're not at BOF
                            if (self.position.row != 0) {
                                self.position.row -= 1;
                                self.goToLineEnd(self.getCurrentLine(lines.*).*);
                            }
                        } else {
                            self.position.column -|= 1;
                        }
                    },
                    .ctrl => self.goToNextLeftWholeWord(lines.*),
                }
                self.setAmbitiousColumn();
            },
            .right => |modifier| {
                switch (modifier) {
                    .none => {
                        if (self.position.column == self.getCurrentLine(lines.*).items.len) {
                            // Wrap to the next line's start if we're not at EOF
                            if (self.position.row != lines.items.len - 1) {
                                self.position.row += 1;
                                self.position.column = 0;
                            }
                        } else {
                            self.position.column += 1;
                        }
                    },
                    .ctrl => self.goToNextRightWholeWord(lines.*),
                }
                self.setAmbitiousColumn();
            },

            .home => |modifier| {
                switch (modifier) {
                    .none => self.position.column = 0,
                    .ctrl => self.position = .{ .row = 0, .column = 0 },
                }
                self.setAmbitiousColumn();
            },
            .end => |modifier| {
                switch (modifier) {
                    .none => self.goToLineEnd(self.getCurrentLine(lines.*).*),
                    .ctrl => {
                        const last_line_index = @intCast(u16, lines.items.len - 1);
                        const last_line = lines.items[last_line_index];

                        self.position.row = last_line_index;
                        self.goToLineEnd(last_line);
                    },
                }
                self.setAmbitiousColumn();
            },
            .page_up => unreachable,
            .page_down => unreachable,

            .enter => {
                // 1. Split the current line at the cursor's column into two
                const current_line = self.getCurrentLine(lines.*);

                const lineBeforeNewline = current_line.items[0..self.position.column];

                const lineAfterNewline = current_line.items[self.position.column..];
                var allocatedLineAfterNewline = try ArrayList(u8).initCapacity(allocator, lineAfterNewline.len);
                allocatedLineAfterNewline.appendSliceAssumeCapacity(lineAfterNewline);

                // 2. Replace the old line with the line before the newline
                try current_line.replaceRange(0, current_line.items.len, lineBeforeNewline);

                self.position = .{
                    .row = self.position.row + 1,
                    .column = 0,
                };

                // 3. Insert the new line after the newline
                try lines.insert(self.position.row, allocatedLineAfterNewline);
            },
            .tab => try self.insertSlice(lines.*, "    "),

            .backspace => |modifier| {
                if (self.getPreviousCharIndex() == null) {
                    // We are at BOL and there is no character on the left of the cursor to remove
                    if (self.position.row != 0) { // BOF?
                        // Remove the leading newline
                        self.position.row -= 1;
                        const removed_line = lines.orderedRemove(self.position.row);
                        if (removed_line.items.len != 0) {
                            try lines.items[self.position.row].insertSlice(0, removed_line.items);
                            self.position.column = @intCast(u16, removed_line.items.len);
                        }
                        removed_line.deinit();
                    }
                } else {
                    switch (modifier) {
                        .none => {
                            // Remove a single character
                            self.removeCurrentLineChar(lines.*, self.getPreviousCharIndex().?);
                            self.position.column -= 1;
                        },
                        .ctrl => {
                            // Remove a whole word

                            // Go backwards from this point and remove all characters
                            // until we hit a space or BOL
                            var remove_spaces = true;
                            while (self.getPreviousCharIndex()) |char_to_remove_index| {
                                const current_line_chars = self.getCurrentLine(lines.*).items;
                                if (current_line_chars[char_to_remove_index] == ' ') {
                                    if (remove_spaces) {
                                        self.removeCurrentLineChar(lines.*, char_to_remove_index);
                                        self.position.column -= 1;
                                        const space_removed = self.removePreviousSuccessiveSpaces(lines.*);
                                        if (space_removed) {
                                            break;
                                        } else {
                                            continue;
                                        }
                                    } else {
                                        break;
                                    }
                                } else {
                                    remove_spaces = false;
                                }

                                self.removeCurrentLineChar(lines.*, char_to_remove_index);
                                self.position.column -= 1;
                            }
                        },
                    }
                }
                self.setAmbitiousColumn();
            },
            .delete => |modifier| {
                if (self.getCurrentCharIndex(lines.*) == null) {
                    // We are at EOL and there is no character on the cursor to remove
                    if (self.position.row != lines.items.len - 1) { // EOF?
                        // Remove the trailing newline
                        const removed_line = lines.orderedRemove(self.position.row + 1);
                        if (removed_line.items.len != 0) {
                            const current_line = self.getCurrentLine(lines.*);
                            try current_line.appendSlice(removed_line.items);
                        }
                        removed_line.deinit();
                    }
                } else {
                    switch (modifier) {
                        .none => {
                            // Remove the character the cursor is on
                            self.removeCurrentLineChar(lines.*, self.getCurrentCharIndex(lines.*).?);
                        },
                        .ctrl => {
                            // Remove a whole word

                            // Go backwards from this point and remove all characters
                            // until we hit a space or BOL
                            var remove_spaces = true;
                            while (self.getCurrentCharIndex(lines.*)) |char_to_remove_index| {
                                const current_line_chars = self.getCurrentLine(lines.*).items;
                                if (current_line_chars[char_to_remove_index] == ' ') {
                                    if (remove_spaces) {
                                        self.removeCurrentLineChar(lines.*, char_to_remove_index);
                                        const space_removed = self.removePreviousSuccessiveSpaces(lines.*);
                                        if (space_removed) {
                                            break;
                                        } else {
                                            continue;
                                        }
                                    } else {
                                        break;
                                    }
                                } else {
                                    remove_spaces = false;
                                }

                                self.removeCurrentLineChar(lines.*, char_to_remove_index);
                            }
                        },
                    }
                }
            },

            .esc => return .exit,
        }
        return null;
    }
};
