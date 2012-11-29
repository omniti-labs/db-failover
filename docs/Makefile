all: failover.html howto.html

failover.html: failover.pod
	pod2html $< > $@

howto.html: howto.pod
	pod2html $< > $@

clean:
	rm -f failover.html howto.html
