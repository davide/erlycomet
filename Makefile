all: code

code: clean
	erl -noshell -pa ebin -eval 'filelib:ensure_dir("./ebin/"), make:all().' -s erlang halt

debug: code
	werl -pa ebin &

clean:
	rm -fv ebin/*.beam
