cmake_minimum_required(VERSION 3.22.1)
project("honeyvpn_launcher")
add_library(honeyvpn_launcher SHARED launcher.c)
target_link_libraries(honeyvpn_launcher log)
