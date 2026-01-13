module textproto;

import std::net, std::io;

faultdef
	INVALID_LINE,
	MESSAGE_TOO_LARGE,
	STATUS_TOO_SHORT,
	STATUS_BAD_FORMAT,
	STATUS_BAD_CODE,
	STATUS_CODE_OUT_OF_RANGE,
	UNEXPECTED_CODE,
	UNEXPECTED_MULTILINE_RESPONSE,
	UNTERMINATED_MULTI_LINE_STATUS;


<* Represents a numeric status response from a server. *>
struct TextProtoStatus (Printable)
{
	<* Pointer to the raw string underlying the status. *>
	String	raw;
	<* The given message's parsed, numeric status code. *>
	int		code;
	<* Pointer to the beginning of the accompanying status message with the code. *>
	String	message;
	<* Whether this line marks a multi-line continuation with the presence of a `-` between `code` and `message`. *>
	bool	continued;
}

fn usz? TextProtoStatus.to_format(&self, Formatter* f) @dynamic
{
	return f.printf("%03d%c%s", self.code, self.continued ? '-' : ' ', self.message);
}

fn bool TextProtoStatus.eq(&self, TextProtoStatus other) @operator(==)
	=> self.code == other.code && self.message == other.message && self.continued == other.continued;

fn TextProtoStatus? parse_code_line(String line)
{
	if (line.len < 4) return STATUS_TOO_SHORT?;
	if (line[3] != ' ' && line[3] != '-') return STATUS_BAD_FORMAT?;

	int parsed_code = 0;
	if (catch @try(parsed_code, line[:3].to_int())) return STATUS_BAD_CODE?;

	if (parsed_code < 100 || parsed_code > 999) return STATUS_CODE_OUT_OF_RANGE?;

	return {
		.code = parsed_code,
		.message = line[4..],
		.continued = line[3] == '-'
	};
}

struct HoldoverValue @local {
	String value;
	bool set;
}

struct TextProtoReader
{
	inline InStream wrapped;
	Allocator allocator;
	HoldoverValue holdover_line;
}

fn TextProtoReader TextProtoReader.init(&self, Allocator allocator, InStream wrapped_stream)
	=> *self = { .allocator = allocator, .wrapped = wrapped_stream };

fn TextProtoReader TextProtoReader.tinit(&self, InStream wrapped_stream) => self.init(tmem, wrapped_stream);

fn void TextProtoReader.destroy(&self)
{
	if (self.allocator == tmem) return;   // do nothing, `@pool` will clean up for us
	allocator::free(self.allocator, self.holdover_line.value);
}

fn String? TextProtoReader.read_line(&self, LineValidationFunc validate_line = fn bool? (String, usz) => true, usz limit = 0)
{
	if (self.holdover_line.set)
	{
		defer self.holdover_line = {};
		if (!validate_line(self.holdover_line.value, 0)!) return INVALID_LINE?;
		return self.holdover_line.value;
	}
	String line;
	defer catch self.holdover_line = { line, true };
	line = io::readline(self.allocator, self.wrapped, limit)!;
	if (!validate_line(line, 0)!) return INVALID_LINE?;
	return line;
}

fn String? TextProtoReader.read_continued_line(&self, LineValidationFunc validate_first_line = fn bool? (String, usz) => true, usz limit = 0)
{
	usz total = 0;
	usz i = 0;
	String line = self.read_line(validate_first_line, limit)!;
	total += line.len;

	if (!validate_first_line(line, 0)!)
	{
		if (!self.holdover_line.set) self.holdover_line = { line, true }; // preserve
		return INVALID_LINE?;
	}

	@pool()
	{
		DString tmp = dstring::temp_with_capacity(min(limit, 1024));
		tmp.write(line)!;
		if (self.allocator != tmem) allocator::free(self.allocator, line);

		while (true)
		{
			i++;
			if (catch err = @try(line, self.read_line(limit: limit)))
			{
				if (err == io::EOF) break;
				return err?;
			}
			self.holdover_line = { line, true };
			if (!line.len) break;

			String trimmed = line.trim_left(" \t\r\f\v");
			if (trimmed.len == line.len) break;  // no left whitespace was trimmed == end of multiline string
			trimmed = trimmed.trim_right(" \t\r\f\v");

			total += trimmed.len;
			if (limit > 0 && total > limit) return io::LIMIT_EXCEEDED?;

			tmp.write_byte(' ')!;
			tmp.write(trimmed)!;

			if (self.allocator != tmem) allocator::free(self.allocator, line);
			self.holdover_line = {};
		}

		return tmp.copy_str(self.allocator);
	};
}

fn TextProtoStatus? TextProtoReader.read_code_line(&self, int expected_code = 0, usz limit = 0, bool part_of_multiline = false)
{
	String line;
	defer catch self.holdover_line = { line, true };
	defer try self.holdover_line = {};
	line = self.holdover_line.set ? self.holdover_line.value : self.read_line(limit: limit)!;
	TextProtoStatus s = parse_code_line(line)!;
	if (s.continued && !part_of_multiline) return UNEXPECTED_MULTILINE_RESPONSE?;
	switch
	{
		case expected_code == 0: break; // do nothing
		case expected_code < 10:
			if (expected_code != s.code / 100) return UNEXPECTED_CODE?;
		case expected_code < 100:
			if (expected_code != s.code / 10) return UNEXPECTED_CODE?;
		default:
			if (expected_code != s.code) return UNEXPECTED_CODE?;
	}
	return s;
}

fn TextProtoStatus? TextProtoReader.read_continued_code_line(&self, int expected_code = 0, usz limit = 0)
{
	usz total = 0;
	usz i = 0;
	TextProtoStatus status = self.read_code_line(expected_code, limit, true)!;
	int required_matching_code = status.code;
	String line = status.raw;
	total += status.raw.len;

	@pool()
	{
		DString tmp = dstring::temp_with_capacity(min(limit, 1024));
		tmp.write(status.message)!;
		if (self.allocator != tmem) allocator::free(self.allocator, status.raw);

		while (true)
		{
			i++;
			if (catch err = @try(status, self.read_code_line(required_matching_code, limit, true)))
			{
				switch (err)
				{
					case io::EOF: break; // end of stream, not an error
					case STATUS_BAD_FORMAT:
						// the header most likely didn't stop using the continuation mark '-' on its last response
						//   line, so the buffer's trying to read into the next "content" line
						return UNTERMINATED_MULTI_LINE_STATUS?;
				}
				return err?;
			}

			String trimmed = status.message.trim_right(" \t\r\f\v");

			total += trimmed.len;
			if (limit > 0 && total > limit) return io::LIMIT_EXCEEDED?;

			tmp.write_byte('\n')!;
			tmp.write(trimmed)!;

			if (self.allocator != tmem) allocator::free(self.allocator, status.raw);
			self.holdover_line = {};

			if (!status.continued) break; // this is no longer a continuation, indicating the end of the multiline response
			// ^ this check occurs at the end of the loop because the final status message can have its own message too
		}

		return {
			.code = required_matching_code,
			.message = tmp.copy_str(self.allocator),
			.continued = false,
		};
	};
}
