# FindFFMPEG — locates libavformat/libavcodec/libavutil/libswscale/libswresample.
# Inputs:  FFMPEG_DIR (cmake var or env), defaults to common homebrew locations.
# Outputs: imported targets FFMPEG::avformat FFMPEG::avcodec FFMPEG::avutil
#          FFMPEG::swscale FFMPEG::swresample

foreach(_comp avformat avcodec avutil swscale swresample)
  string(TOUPPER ${_comp} _COMP)

  find_path(FFMPEG_${_COMP}_INCLUDE_DIR
    NAMES ${_comp}.h
    HINTS
      ${FFMPEG_DIR}
      ENV FFMPEG_DIR
      /opt/homebrew/opt/ffmpeg
      /usr/local/opt/ffmpeg
    PATH_SUFFIXES include/lib${_comp} include/x86_64-w64-mingw32/lib${_comp}
  )

  find_library(FFMPEG_${_COMP}_LIBRARY
    NAMES ${_comp}
    HINTS
      ${FFMPEG_DIR}
      ENV FFMPEG_DIR
      /opt/homebrew/opt/ffmpeg
      /usr/local/opt/ffmpeg
    PATH_SUFFIXES bin lib
  )

  if(FFMPEG_${_COMP}_INCLUDE_DIR)
    get_filename_component(FFMPEG_${_COMP}_INCLUDE_ROOT "${FFMPEG_${_COMP}_INCLUDE_DIR}" DIRECTORY)
  else()
    set(FFMPEG_${_COMP}_INCLUDE_ROOT "FFMPEG_${_COMP}_INCLUDE_ROOT-NOTFOUND")
  endif()
endforeach()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(FFMPEG REQUIRED_VARS
  FFMPEG_AVCODEC_INCLUDE_ROOT FFMPEG_AVCODEC_LIBRARY
  FFMPEG_AVFORMAT_INCLUDE_ROOT FFMPEG_AVFORMAT_LIBRARY
  FFMPEG_AVUTIL_INCLUDE_ROOT FFMPEG_AVUTIL_LIBRARY
  FFMPEG_SWSCALE_INCLUDE_ROOT FFMPEG_SWSCALE_LIBRARY
  FFMPEG_SWRESAMPLE_INCLUDE_ROOT FFMPEG_SWRESAMPLE_LIBRARY
)

if(NOT TARGET FFMPEG::avcodec)
  foreach(_comp avcodec avformat avutil swscale swresample)
    string(TOUPPER ${_comp} _COMP)
    add_library(FFMPEG::${_comp} UNKNOWN IMPORTED)
    set_target_properties(FFMPEG::${_comp} PROPERTIES
      IMPORTED_LOCATION ${FFMPEG_${_COMP}_LIBRARY}
      INTERFACE_INCLUDE_DIRECTORIES ${FFMPEG_${_COMP}_INCLUDE_ROOT}
    )
    unset(FFMPEG_${_COMP}_INCLUDE_ROOT CACHE)
  endforeach()
endif()

mark_as_advanced(
  FFMPEG_AVCODEC_INCLUDE_DIR FFMPEG_AVCODEC_LIBRARY
  FFMPEG_AVFORMAT_INCLUDE_DIR FFMPEG_AVFORMAT_LIBRARY
  FFMPEG_AVUTIL_INCLUDE_DIR FFMPEG_AVUTIL_LIBRARY
  FFMPEG_SWSCALE_INCLUDE_DIR FFMPEG_SWSCALE_LIBRARY
  FFMPEG_SWRESAMPLE_INCLUDE_DIR FFMPEG_SWRESAMPLE_LIBRARY
)
