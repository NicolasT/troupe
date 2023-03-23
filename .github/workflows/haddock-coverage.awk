BEGIN {
	in_block=0
	exit_code=0
}

END {
	if(exit_code!=0) {
		exit exit_code
	}
}

/^Running Haddock on library for troupe-/ {
	in_block=1
}

/^Documentation created:/ {
	in_block=0
}

/^[[:space:]]+[[:digit:]]+% \([0-9\/ ]+\) in / {
	if(in_block==1) {
		print $0

		if($1!="100%") {
			exit_code=1
		}
	}
}
