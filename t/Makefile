
ALL_TESTS:=$(wildcard t[0-9][0-9][0-9]-*)

.PHONY: ${ALL_TESTS}
all: ${ALL_TESTS}
FORCE:
${ALL_TESTS}: FORCE
	perl $@

