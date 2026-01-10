module testing;
import textproto, std::io;

alias TestBuf = TextProtoReader{ByteBuffer};

macro TestBuf @make_testbuf(#expr)
{
	TestBuf r;
	ByteBuffer _r;
	_r.tinit(1024);
	(void)_r.write(#expr)!!;
	return r.tinit(_r);
}

fn void main()
{
	TestBuf r = @make_testbuf("My-Header: It starts with\n\tOne thing, I don't know why\n\tIt doesn't even matter how hard you try\n\n");
	r.read_continued_line()!!;
}