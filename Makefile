test:
	docker build . -f tests/Dockerfile --build-arg PLUGIN_NAME=shellpad.nvim -t shellpad/shellpad.nvim:tests
	docker run shellpad/shellpad.nvim:tests

test-highlight:
	@echo 'shellpad: highlight {re: "\\(\\d\\+\\.\\)\\{3\\}\\d\\+", fg: "#66aa66", bg: "NONE"}'
	ping -c 3 -i 0.1 8.8.8.8
