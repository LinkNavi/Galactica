CXX      = bear -- g++
CXXFLAGS = -std=c++20 -Wall -Wextra -O2 -fPIC -fstack-protector-strong
INCLUDES = -Iinclude
LDFLAGS  = -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl

BUILD_DIR   = build
MODULES_DIR = modules

SRCS = src/main.cpp \
       src/core.cpp \
       src/db.cpp \
       src/install.cpp \
       src/commands.cpp \
       src/modules.cpp

OBJS = $(SRCS:src/%.cpp=$(BUILD_DIR)/%.o)

HEADERS = include/dreamland.h include/dreamland_module.h

.PHONY: all clean dreamland modules workspace install strip

# ── Default target ────────────────────────────────────────────────────────────
all: dreamland modules

# ── Dreamland binary ──────────────────────────────────────────────────────────
dreamland: $(BUILD_DIR)/dreamland

$(BUILD_DIR)/dreamland: $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built: dreamland"

$(BUILD_DIR)/%.o: src/%.cpp $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

# ── Modules ───────────────────────────────────────────────────────────────────
modules: workspace

workspace: $(BUILD_DIR)/workspace.so

$(BUILD_DIR)/workspace.so: $(MODULES_DIR)/workspace/src/workspace.cpp include/dreamland_module.h
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -shared $(INCLUDES) -o $@ $<
	@echo "Built: workspace.so"

# ── Strip ─────────────────────────────────────────────────────────────────────
strip: dreamland
	strip --strip-unneeded $(BUILD_DIR)/dreamland

# ── Install ───────────────────────────────────────────────────────────────────
install: all
	@mkdir -p ~/.local/bin
	@mkdir -p ~/.local/share/dreamland/modules
	cp $(BUILD_DIR)/dreamland ~/.local/bin/
	ln -sf ~/.local/bin/dreamland ~/.local/bin/dl
	cp $(BUILD_DIR)/workspace.so ~/.local/share/dreamland/modules/
	@echo "Installed to ~/.local/bin/ and ~/.local/share/dreamland/modules/"

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR)
