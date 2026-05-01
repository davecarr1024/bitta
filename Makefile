.PHONY: test typecheck check install

install:
	pip install -e ".[dev]" -q

test:
	python -m pytest; e=$$?; [ $$e -eq 0 ] || [ $$e -eq 5 ]

typecheck:
	python -m mypy bitta

check: typecheck test
