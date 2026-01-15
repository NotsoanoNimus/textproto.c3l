module textproto_test::reader;

import textproto;
import std::io;

const String CORPUS_SMTP = $embed("corpus/smtp.txt");
const String CORPUS_HTTP = $embed("corpus/http.txt");
const String CORPUS_FTP = $embed("corpus/ftp.txt");

macro TextProtoReader @make_testbuf(#expr, bool $temp_allocator = true, usz size = 1024)
{
	TextProtoReader r;
	ByteBuffer _r;
	_r.tinit(size);
	(void)_r.write(#expr)!!;
	return $temp_allocator ??? r.tinit(&_r) : r.init(mem, &_r);
}


// ========================================================================================
module textproto_test::reader @test;

import textproto;
import std::io;

fn void read_line_simple()
{
	TextProtoReader r = @make_testbuf("line1\nline2\nno-endl");
	test::@check(r.read_line(limit: 8)!! == "line1");
	test::@check(r.read_line(limit: 8)!! == "line2");
	test::@check(r.read_line(limit: 8)!! == "no-endl");
}

fn void read_line_simple_crlf()
{
	TextProtoReader r = @make_testbuf("line1\r\nline2\r\n");
	test::@check(r.read_line(limit: 8)!! == "line1");
	test::@check(r.read_line(limit: 8)!! == "line2");
}

fn void read_line_limit()
{
	TextProtoReader r = @make_testbuf("line1\nline2\n");
	test::@check(r.read_line(limit: 5)!! == "line1");

	r = @make_testbuf("line1\nline2\n");
	test::@error(r.read_line(limit: 4), io::LIMIT_EXCEEDED);
}

fn void read_code_line_simple()
{
	TextProtoReader r = @make_testbuf(CORPUS_FTP);
	test::@error(r.read_code_line(), textproto::UNEXPECTED_MULTILINE_RESPONSE);
	r = @make_testbuf("220 mysite.xmit.xyz ESMTP");
	TextProtoStatus s = r.read_code_line()!!;
	test::@check(s.code == 220);
	test::@check(s.message == "mysite.xmit.xyz ESMTP");
	test::@check(s.continued == false);
}

fn void read_code_line_fuzzy_matching()
{
	static String sample = "220 hello world";
	TextProtoReader r = @make_testbuf(sample);
	(void)r.read_code_line(2)!!; // ok
	r = @make_testbuf(sample);
	(void)r.read_code_line(22)!!; // ok
	r = @make_testbuf(sample);
	test::@error(r.read_code_line(3), textproto::UNEXPECTED_CODE);
	r = @make_testbuf(sample);
	test::@error(r.read_code_line(23), textproto::UNEXPECTED_CODE);
}

fn void read_code_line_unexpected()
{
	TextProtoReader r = @make_testbuf("220 Welcome to my FTP server");
	test::@error(r.read_code_line(404), textproto::UNEXPECTED_CODE);
}

fn void read_code_line_errors()
{
	TextProtoReader r = @make_testbuf("hi");
	test::@error(r.read_code_line(), textproto::STATUS_TOO_SHORT);
	r = @make_testbuf("123456 something");
	test::@error(r.read_code_line(), textproto::STATUS_BAD_FORMAT);
	r = @make_testbuf("NaN something");
	test::@error(r.read_code_line(), textproto::STATUS_BAD_CODE);
	r = @make_testbuf("007 something");
	test::@error(r.read_code_line(), textproto::STATUS_CODE_OUT_OF_RANGE);
}

fn void read_continued_line_simple()
{
	TextProtoReader r = @make_testbuf("My-Header: It starts with\n\tOne thing, I don't know why\n\tIt doesn't even matter how hard you try\n\n");
	test::@check(r.read_continued_line()!! == "My-Header: It starts with One thing, I don't know why It doesn't even matter how hard you try");
}

fn void read_mixed_continued_and_single()
{
	TextProtoReader r = @make_testbuf(`From: <me@you.we>
Date: January 1st, 1970 8)
Multiple: Header
		   in the middle
		of everything`"\t\t"`
 here.


Another: simple header

And: One more

`);
	test::@check(r.read_continued_line()!! == "From: <me@you.we>");
	test::@check(r.read_continued_line()!! == "Date: January 1st, 1970 8)");
	test::@check(r.read_continued_line()!! == "Multiple: Header in the middle of everything here.");
	test::@check(r.read_continued_line()!! == "");
	test::@check(r.read_continued_line()!! == "");
	test::@check(r.read_continued_line()!! == "Another: simple header");
	test::@check(r.read_continued_line()!! == "");
	test::@check(r.read_continued_line()!! == "And: One more");
}

fn void read_continued_line_with_validation()
{
	LineValidationFunc caps_predicate = fn bool? (String line, usz num) => line[0] >= 'A' && line[0] <= 'Z';
	TextProtoReader r = @make_testbuf("One: Two\r\nThree: Four\r\n\tFive\r\n\tSix\r\nSeven: Eight\r\nine");
	test::@check(r.read_continued_line(validate_first_line: caps_predicate)!! == "One: Two");
	test::@check(r.read_continued_line(validate_first_line: caps_predicate)!! == "Three: Four Five Six");
	test::@check(r.read_continued_line(validate_first_line: caps_predicate)!! == "Seven: Eight");
	test::@error(r.read_continued_line(validate_first_line: caps_predicate), textproto::INVALID_LINE);
}

fn void read_continued_line_mixed_leaks_check()
{
	TextProtoReader r = @make_testbuf(`From: <me@you.we>
Date: January 1st, 1970 8)
Multiple: Header
		   in the middle
		of everything`"\t\t"`
 here.


Another: simple header

And: One more

`, false);
	static String[] expected = { "From: <me@you.we>", "Date: January 1st, 1970 8)", "Multiple: Header in the middle of everything here.", "", "", "Another: simple header", "", "And: One more" };
	$for usz $x = 0; $x < 5; $x++:
	{
		String line = r.read_continued_line()!!;
		test::@check(line == expected[$x], "Line mismatch at index %d. Got '%s', but expected '%s'.", $x, line, expected[$x]);
		allocator::free(r.allocator, line);
	}
	$endfor

	r.destroy();
}

fn void read_continued_code_line_simple()
{
	TextProtoReader r = @make_testbuf(CORPUS_FTP);
	test::@check(r.read_continued_code_line()!! == (TextProtoStatus){ .code = 220, .message = "Welcome to Example FTP Server\n  We like to have fun around here.\n-----", .continued = false });
}

fn void read_continued_code_line_errors()
{
	// status code changes midway through the banner
	TextProtoReader r = @make_testbuf("220-A\n221 B\ncontent");
	test::@error(r.read_continued_code_line(), textproto::UNEXPECTED_CODE);
	// banner's final line still contains the continuation mark '-'
	r = @make_testbuf("220-A\n220-B\ncontent");
	test::@error(r.read_continued_code_line(), textproto::UNTERMINATED_MULTI_LINE_STATUS);
}


// ==================================================================================================================
// Moving on to more verbatim tests from the Go 'textproto' package.
fn void go_read_line()
{
	TextProtoReader r = @make_testbuf("line1\nline2\n");
	test::@check(r.read_line()!! == "line1");
	test::@check(r.read_line()!! == "line2");
	test::@error(r.read_line(), io::EOF);
}

fn void go_read_long_line()
{
	char* tmp = mem::talloc_array(char, 10_002);
	tmp[:10_000] = 'a';
	tmp[10_000] = '\r';
	tmp[10_001] = '\n';
	TextProtoReader r = @make_testbuf(tmp[:10_002], size: 10_200);
	String retval = r.read_line()!!;
	test::@check(retval == tmp[:10_000]);
	test::@error(r.read_line(), io::EOF);
}

fn void go_read_continued_line()
{
	TextProtoReader r = @make_testbuf("line1\nline\n 2\nline3\n");
	test::@check(r.read_continued_line()!! == "line1");
	test::@check(r.read_continued_line()!! == "line 2");
	test::@check(r.read_continued_line()!! == "line3");
	// test::@error(r.read_continued_line(), io::EOF); // TODO
}

fn void go_read_code_line()
{
	TextProtoReader r = @make_testbuf("123 hi\n234 bye\n345 no way\n");
	test::@check(r.read_code_line()!! == (TextProtoStatus){ .code = 123, .message = "hi", .continued = false });
	test::@check(r.read_code_line(23)!! == (TextProtoStatus){ .code = 234, .message = "bye", .continued = false });
	test::@error(r.read_code_line(346), textproto::UNEXPECTED_CODE);
	test::@check(r.read_code_line()!! == (TextProtoStatus){ .code = 345, .message = "no way", .continued = false });
}

fn void go_read_dot_lines()
{
	const String[] EXPECTED = { "dotlines", "foo", ".bar", "..baz", "quux", "" };
	TextProtoReader r = @make_testbuf("dotlines\r\n.foo\r\n..bar\n...baz\nquux\r\n\r\n.\r\nanother\n");
	String[] lines = r.read_dot_lines()!!;
	foreach (i, wants : EXPECTED) test::eq(wants, lines[i]);
	test::@error(r.read_dot_lines(), textproto::UNEXPECTED_EOF); // because 'another\n' doesn't end with [CRLF.CRLF]
}

fn void go_read_dot_bytes()
{
	const char[] EXPECTED = "dotlines\nfoo\n.bar\n..baz\nquux\n\n";
	TextProtoReader r = @make_testbuf("dotlines\r\n.foo\r\n..bar\n...baz\nquux\r\n\r\n.\r\nanot.her\r\n");
	char[] retval = r.read_dot_bytes()!!;
	test::eq(retval, EXPECTED);
}

fn void go_read_mime_header()
{
	//
}