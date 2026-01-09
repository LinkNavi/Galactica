CXX = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 -fPIC
LDFLAGS = -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl

BUILD_DIR = build
MODULES_DIR = modules

.PHONY: all clean dreamland modules workspace install

all: dreamland modules

dreamland: $(BUILD_DIR)/dreamland

$(BUILD_DIR)/dreamland: src/main.cpp include/dreamland_module.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -o $@ src/main.cpp $(LDFLAGS)
	@echo "Built: dreamland"

modules: workspace

workspace: $(BUILD_DIR)/workspace.so

$(BUILD_DIR)/workspace.so: modules/workspace/src/workspace.cpp include/dreamland_module.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -shared -I include -o $@ modules/workspace/src/workspace.cpp
	@echo "Built: workspace.so"

install: all
	@mkdir -p ~/.local/bin
	@mkdir -p ~/.local/share/dreamland/modules
	cp $(BUILD_DIR)/dreamland ~/.local/bin/
	ln -sf ~/.local/bin/dreamland ~/.local/bin/dl
	cp $(BUILD_DIR)/workspace.so ~/.local/share/dreamland/modules/
	@echo "Installed to ~/.local/bin/ and ~/.local/share/dreamland/modules/"

clean:
	rm -rf $(BUILD_DIR)
