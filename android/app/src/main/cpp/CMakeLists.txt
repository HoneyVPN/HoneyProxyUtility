cmake_minimum_required(VERSION 3.22.1)
project("honeyvpn_launcher")
add_library(honeyvpn_launcher SHARED launcher.c owned_child.c latency_process.c latency_launcher.c)
target_link_libraries(honeyvpn_launcher log)
