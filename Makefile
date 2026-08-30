.PHONY: app debug run icon clean

app:
	bash scripts/bundle.sh release

debug:
	bash scripts/bundle.sh debug

run: app
	open dist/Brewer.app

icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build dist
