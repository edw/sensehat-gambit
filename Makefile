brot: sensehat.scm
	gsc -o brot -exe -postlude '(test-iter-brot)' \
	-cc-options '-U___SINGLE_HOST -O2' sensehat
