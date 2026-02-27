CXX      = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17 -fstack-protector-strong
INCLUDES = -Iinclude

SRCS = src/main.cpp \
       src/mount.cpp \
       src/loader.cpp \
       src/service_mgr.cpp \
       src/socket_ctl.cpp \
       src/reaper.cpp

OBJS = $(SRCS:src/%.cpp=build/%.o)
BIN  = build/airride

.PHONY: all clean

all: $(BIN)

build/%.o: src/%.cpp include/airride.h include/service.h
	$(shell test -d build || mkdir build)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(BIN): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ -lpthread

clean:
	$(shell rm -rf build)