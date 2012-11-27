all: failover.html

failover.html: failover.pod
	pod2html $< > $@

clean:
	rm -f failover.html
