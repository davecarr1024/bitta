BUILD_DIR := build

.PHONY: configure build test check clean

configure:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Debug

build: configure
	cmake --build $(BUILD_DIR) -j

test: build
	ctest --test-dir $(BUILD_DIR) --output-on-failure -j

check: test

clean:
	rm -rf $(BUILD_DIR)
