
SCRIPT=dissem.pl

all:
	@perl -c ${SCRIPT}

test: all
	$(MAKE) -C t all
