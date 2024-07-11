README.md: README-unprocessed.md
	pandoc 	--lua-filter=pandoc-include-code.lua \
		--from=gfm+attributes \
		--to=gfm \
		--output $@ \
		$? 
