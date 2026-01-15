module textproto;

import std::net, std::io, std::collections;

faultdef
	INVALID_LINE,
	MESSAGE_TOO_LARGE,
	STATUS_TOO_SHORT,
	STATUS_BAD_FORMAT,
	STATUS_BAD_CODE,
	STATUS_CODE_OUT_OF_RANGE,
	UNEXPECTED_CODE,
	UNEXPECTED_EOF,
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
	if (line.len < 4) return STATUS_TOO_SHORT~;
	if (line[3] != ' ' && line[3] != '-') return STATUS_BAD_FORMAT~;

	int parsed_code = 0;
	if (catch @try(parsed_code, line[:3].to_int())) return STATUS_BAD_CODE~;

	if (parsed_code < 100 || parsed_code > 999) return STATUS_CODE_OUT_OF_RANGE~;

	return {
		.code = parsed_code,
		.message = line[4..],
		.continued = line[3] == '-'
	};
}

struct TextProtoReader
{
	inline InStream wrapped;
	TextProtoDotReader* dot;
	Allocator allocator;
	Maybe{String} holdover_line;
}

fn TextProtoReader TextProtoReader.init(&self, Allocator allocator, InStream wrapped_stream)
	=> *self = { .allocator = allocator, .wrapped = wrapped_stream };

fn TextProtoReader TextProtoReader.tinit(&self, InStream wrapped_stream) => self.init(tmem, wrapped_stream);

fn void TextProtoReader.destroy(&self)
{
	if (self.allocator == tmem) return;   // do nothing, `@pool` will clean up for us
	if (try self.holdover_line.get()) allocator::free(self.allocator, self.holdover_line.get()!!);
	mem::zero_volatile(@as_char_view(*self));
}

fn String? TextProtoReader.read_line(&self, LineValidationFunc validate_line = fn bool? (String, usz) => true, usz limit = 0)
{
	if (try self.holdover_line.get())
	{
		defer self.holdover_line = maybe::EMPTY{String};
		if (!validate_line(self.holdover_line.get()!!, 0)!) return INVALID_LINE~;
		return self.holdover_line.get()!!;
	}
	self.close_dot();
	String line;
	defer catch self.holdover_line = maybe::value{String}(line);
	line = io::readline(self.allocator, self.wrapped, limit)!;
	if (!validate_line(line, 0)!) return INVALID_LINE~;
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
		if (catch self.holdover_line.get()) self.holdover_line = maybe::value{String}(line); // preserve
		return INVALID_LINE~;
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
				return err~;
			}
			self.holdover_line = maybe::value{String}(line);
			if (!line.len) break;

			String trimmed = line.trim_left(" \t\r\f\v");
			if (trimmed.len == line.len) break;  // no left whitespace was trimmed == end of multiline string
			trimmed = trimmed.trim_right(" \t\r\f\v");

			total += trimmed.len;
			if (limit > 0 && total > limit) return io::LIMIT_EXCEEDED~;

			tmp.write_byte(' ')!;
			tmp.write(trimmed)!;

			if (self.allocator != tmem) allocator::free(self.allocator, line);
			self.holdover_line = maybe::EMPTY{String};
		}

		return tmp.copy_str(self.allocator);
	};
}

fn TextProtoStatus? TextProtoReader.read_code_line(&self, int expected_code = 0, usz limit = 0, bool part_of_multiline = false)
{
	String line;
	defer catch self.holdover_line = maybe::value{String}(line);
	defer try self.holdover_line = maybe::EMPTY{String};
	line = self.holdover_line.get() ?? self.read_line(limit: limit)!;
	TextProtoStatus s = parse_code_line(line)!;
	if (s.continued && !part_of_multiline) return UNEXPECTED_MULTILINE_RESPONSE~;
	switch
	{
		case expected_code == 0: break; // do nothing
		case expected_code < 10:
			if (expected_code != s.code / 100) return UNEXPECTED_CODE~;
		case expected_code < 100:
			if (expected_code != s.code / 10) return UNEXPECTED_CODE~;
		default:
			if (expected_code != s.code) return UNEXPECTED_CODE~;
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
						return UNTERMINATED_MULTI_LINE_STATUS~;
				}
				return err~;
			}

			String trimmed = status.message.trim_right(" \t\r\f\v");

			total += trimmed.len;
			if (limit > 0 && total > limit) return io::LIMIT_EXCEEDED~;

			tmp.write_byte('\n')!;
			tmp.write(trimmed)!;

			if (self.allocator != tmem) allocator::free(self.allocator, status.raw);
			self.holdover_line = maybe::EMPTY{String};

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

fn void TextProtoReader.read_mime_header(&self)
{
	//
}

fn void TextProtoReader.close_dot(&self)
{
	if (self.dot == null) return;
	char[128] drain @noinit;
	while (self.dot != null) (void)self.dot.read(drain[..]);
}

fn TextProtoDotReader* TextProtoReader.init_dot_reader(&self)
{
	self.close_dot();
	self.dot = allocator::new(self.allocator, TextProtoDotReader);
	self.dot.reader = self;
	return self.dot;
}

fn char[]? TextProtoReader.read_dot_bytes(&self)
{
	usz block = 0;
	usz array_sz = 128;
	char[128] drain @noinit;
	TextProtoDotReader* r = self.init_dot_reader();
	char* res = allocator::alloc_array(self.allocator, char, 128);
	for (usz siphoned = 0; ; block++)
	{
		if (block * 128 >= array_sz) // grow
		{
			array_sz *= 2;
			res = allocator::realloc_array(self.allocator, res, char, array_sz);
		}
		Outcome{usz} result = r.read(drain[..]);
		res[block * 128 : result.value] = drain[:result.value];
		if (catch err = result.unwrap())
		{
			if (err != io::EOF) return err?;
			return res[ : (block * 128) + result.value];
		}
	}
}

fn String[]? TextProtoReader.read_dot_lines(&self)
{
	usz pointers = 32;
	usz n;
	String* res = allocator::alloc_array(self.allocator, String, pointers);
	for (;;)
	{
		String line;
		if (catch err = @try(line, self.read_line()))
		{
			return (err == io::EOF ? UNEXPECTED_EOF : err)~;
		}
		if (line.len > 0 && line[0] == '.')
		{
			if (line.len == 1) break;
			line = line[1..];
		}
		if (n + 1 >= pointers)
		{
			pointers *= 2;
			res = allocator::realloc_array(self.allocator, res, String, pointers);
		}
		res[n++] = line;
	};
	return res[:n];
}

struct TextProtoDotReader
{
	inline TextProtoReader* reader;
	DotReaderState state;
}

enum DotReaderState
{
	BEGIN_LINE,
	DOT,
	DOT_CR,
	CR,
	DATA,
	EOF
}

fn Outcome{usz} TextProtoDotReader.read(&self, char[] into)
{
	usz n;
	char unread;
	InStream* reader = &self.reader.wrapped;

	while (n < into.len && self.state != EOF)
	{
		char c;
		if (unread != 0)
		{
			c = unread;
			unread = 0;
		}
		else
		{
			if (catch err = @try(c, reader.read_byte()))
			{
				return @outcome(n, err == io::EOF ? UNEXPECTED_EOF : err);
			}
		}
		switch (self.state)
		{
			case BEGIN_LINE:
				if (c == '.') { self.state = DOT; continue; }
				if (c == '\r') { self.state = CR; continue; }
				self.state = DATA;
			case DOT:
				if (c == '\r') { self.state = DOT_CR; continue; }
				if (c == '\n') { self.state = EOF; continue; }
				self.state = DATA;
			case DOT_CR:
				if (c == '\n') { self.state = EOF; continue; }
				unread = c;
				c = '\r';
				self.state = DATA;
			case CR:
				if (c == '\n') { self.state = BEGIN_LINE; break; }
				unread = c;
				c = '\r';
				self.state = DATA;
			case DATA:
				if (c == '\r') { self.state = CR; continue; }
				if (c == '\n') self.state = BEGIN_LINE;
			default:
		}
		into[n++] = c;
	}
	if (self.state == EOF && self.reader.dot == self)
	{
		allocator::free(self.reader.allocator, self.reader.dot);
		self.reader.dot = null;
	}
	if (self.state == EOF) return @outcome(n, io::EOF);
	return @outcome(n);
}
