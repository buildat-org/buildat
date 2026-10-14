/*! \file binary.hpp
    \brief Binary input and output archives */
/*
  Copyright (c) 2014, Randolph Voorhies, Shane Grant
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:
      * Redistributions of source code must retain the above copyright
        notice, this list of conditions and the following disclaimer.
      * Redistributions in binary form must reproduce the above copyright
        notice, this list of conditions and the following disclaimer in the
        documentation and/or other materials provided with the distribution.
      * Neither the name of cereal nor the
        names of its contributors may be used to endorse or promote products
        derived from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  DISCLAIMED. IN NO EVENT SHALL RANDOLPH VOORHIES OR SHANE GRANT BE LIABLE FOR ANY
  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
#ifndef CEREAL_ARCHIVES_PORTABLE_BINARY_HPP_
#define CEREAL_ARCHIVES_PORTABLE_BINARY_HPP_

#include <cereal/cereal.hpp>
#include <sstream>
#include <limits>

namespace cereal
{
  namespace portable_binary_detail
  {
    //! Returns true if the current machine is little endian
    /*! @ingroup Internal */
    inline bool is_little_endian()
    {
      static std::int32_t test = 1;
      return *reinterpret_cast<std::int8_t*>( &test ) == 1;
    }

    //! Swaps the order of bytes for some chunk of memory
    /*! @param data The data as a uint8_t pointer
        @tparam DataSize The true size of the data
        @ingroup Internal */
    template <std::size_t DataSize>
    inline void swap_bytes( std::uint8_t * data )
    {
      for( std::size_t i = 0, end = DataSize / 2; i < end; ++i )
        std::swap( data[i], data[DataSize - i - 1] );
    }
  } // end namespace portable_binary_detail

  // ######################################################################
  //! An output archive designed to save data in a compact binary representation portable over different architectures
  /*! This archive outputs data to a stream in an extremely compact binary
      representation with as little extra metadata as possible.

      This archive will record the endianness of the data and assuming that
      the user takes care of ensuring serialized types are the same size
      across machines, is portable over different architectures.

      When using a binary archive and a file stream, you must use the
      std::ios::binary format flag to avoid having your data altered
      inadvertently.

      \warning This archive has not been thoroughly tested across different architectures.
               Please report any issues, optimizations, or feature requests at
               <a href="www.github.com/USCiLab/cereal">the project github</a>.

    \ingroup Archives */
  class PortableBinaryOutputArchive : public OutputArchive<PortableBinaryOutputArchive, AllowEmptyClassElision>
  {
    public:
      //! Construct, outputting to the provided stream
      /*! @param stream The stream to output to.  Can be a stringstream, a file stream, or
        even cout! */
      PortableBinaryOutputArchive(std::ostream & stream) :
        OutputArchive<PortableBinaryOutputArchive, AllowEmptyClassElision>(this),
        itsStream(stream)
      {
        this->operator()( portable_binary_detail::is_little_endian() );
      }

      //! Writes size bytes of data to the output stream
      void saveBinary( const void * data, std::size_t size )
      {
        auto const writtenSize = static_cast<std::size_t>( itsStream.rdbuf()->sputn( reinterpret_cast<const char*>( data ), size ) );

        if(writtenSize != size)
          throw Exception("Failed to write " + std::to_string(size) + " bytes to output stream! Wrote " + std::to_string(writtenSize));
      }

    private:
      std::ostream & itsStream;
  };

  // ######################################################################
  //! An input archive designed to load data saved using PortableBinaryOutputArchive
  /*! This archive outputs data to a stream in an extremely compact binary
      representation with as little extra metadata as possible.

      This archive will load the endianness of the serialized data and
      if necessary transform it to match that of the local machine.  This comes
      at a significant performance cost compared to non portable archives if
      the transformation is necessary, and also causes a small performance hit
      even if it is not necessary.

      It is recommended to use portable archives only if you know that you will
      be sending binary data to machines with different endianness.

      The archive will do nothing to ensure types are the same size - that is
      the responsibility of the user.

      When using a binary archive and a file stream, you must use the
      std::ios::binary format flag to avoid having your data altered
      inadvertently.

      \warning This archive has not been thoroughly tested across different architectures.
               Please report any issues, optimizations, or feature requests at
               <a href="www.github.com/USCiLab/cereal">the project github</a>.

    \ingroup Archives */
  class PortableBinaryInputArchive : public InputArchive<PortableBinaryInputArchive, AllowEmptyClassElision>
  {
    public:
      //! Construct, loading from the provided stream
      /*! @param stream The stream to read from. */
      PortableBinaryInputArchive(std::istream & stream) :
        InputArchive<PortableBinaryInputArchive, AllowEmptyClassElision>(this),
        itsStream(stream),
        itsStringBuf(dynamic_cast<std::stringbuf *>(stream.rdbuf())),
        itsConvertEndianness( false )
      {
        // buildat: a byte, not a bool -- it is the stream's first, and the
        // stream comes from the wire
        std::uint8_t streamLittleEndian = 0;
        this->operator()( streamLittleEndian );
        itsConvertEndianness = portable_binary_detail::is_little_endian() ^ (streamLittleEndian != 0);
      }

      //! Reads size bytes of data from the input stream
      /*! @param data The data to save
          @param size The number of bytes in the data
          @tparam DataSize T The size of the actual type of the data elements being loaded */
      template <std::size_t DataSize>
      void loadBinary( void * const data, std::size_t size )
      {
        // load data
        auto const readSize = static_cast<std::size_t>( itsStream.rdbuf()->sgetn( reinterpret_cast<char*>( data ), size ) );

        if(readSize != size)
          throw Exception("Failed to read " + std::to_string(size) + " bytes from input stream! Read " + std::to_string(readSize));

        // flip bits if needed
        if( itsConvertEndianness )
        {
          std::uint8_t * ptr = reinterpret_cast<std::uint8_t*>( data );
          for( std::size_t i = 0; i < size; i += DataSize )
            portable_binary_detail::swap_bytes<DataSize>( ptr );
        }
      }

      //! buildat: a container's size off the wire is checked against what
      //! is left to read before the container is made that size -- every
      //! element of a binary archive takes at least a byte, so a size past
      //! the bytes left is not a real one, and a packet of twenty bytes
      //! claiming 2^30 strings made them all first ([SECURITY_RUN_1]). A
      //! string stream only: a file's in_avail() is not what is left.
      void checkSize( std::uint64_t size )
      {
        if( itsStringBuf && size > static_cast<std::uint64_t>( itsStringBuf->in_avail() ) )
          throw Exception("A size of " + std::to_string(size) + " past the " +
              std::to_string(itsStringBuf->in_avail()) + " bytes left in the input stream");
      }

      //! buildat: the string stream's buffer (null for another stream), for
      //! interface::Record to read a record's fields in place and skip a
      //! newer minor's tail. Looked up once: a cast per container and record
      //! was a measurable part of a registry's load ([RECORD_FRAMING_COST])
      std::stringbuf * stringbuf() { return itsStringBuf; }

    private:
      std::istream & itsStream;
      std::stringbuf * itsStringBuf;
      bool itsConvertEndianness; //!< If set to true, we will need to swap bytes upon loading
  };

  namespace portable_binary_detail
  {
    template <class T> inline void check_size( PortableBinaryOutputArchive &, T const & ) {}
    template <class T> inline void check_size( PortableBinaryInputArchive & ar, T const & size )
    { ar.checkSize( static_cast<std::uint64_t>( size ) ); }
  }

  // ######################################################################
  // Common BinaryArchive serialization functions

  //! Saving for POD types to portable binary
  template<class T> inline
  typename std::enable_if<std::is_arithmetic<T>::value, void>::type
  save(PortableBinaryOutputArchive & ar, T const & t)
  {
    static_assert( !std::is_floating_point<T>::value ||
                   (std::is_floating_point<T>::value && std::numeric_limits<T>::is_iec559),
                   "Portable binary only supports IEEE 754 standardized floating point" );
    ar.saveBinary(std::addressof(t), sizeof(t));
  }

  //! Loading for POD types from portable binary
  template<class T> inline
  typename std::enable_if<std::is_arithmetic<T>::value, void>::type
  load(PortableBinaryInputArchive & ar, T & t)
  {
    static_assert( !std::is_floating_point<T>::value ||
                   (std::is_floating_point<T>::value && std::numeric_limits<T>::is_iec559),
                   "Portable binary only supports IEEE 754 standardized floating point" );
    // buildat: a bool is read as a byte and made a bool, since a byte that
    // is neither 0 nor 1 is not a value a bool may hold (UBSan, util/fuzz,
    // [SECURITY_RUN_1]) and it comes from the wire
    if(std::is_same<T, bool>::value){
      std::uint8_t b = 0;
      ar.template loadBinary<1>(&b, 1);
      t = (b != 0);
      return;
    }
    ar.template loadBinary<sizeof(T)>(std::addressof(t), sizeof(t));
  }

  //! Serializing NVP types to portable binary
  template <class Archive, class T> inline
  CEREAL_ARCHIVE_RESTRICT(PortableBinaryInputArchive, PortableBinaryOutputArchive)
  serialize( Archive & ar, NameValuePair<T> & t )
  {
    ar( t.value );
  }

  //! Serializing SizeTags to portable binary
  template <class Archive, class T> inline
  CEREAL_ARCHIVE_RESTRICT(PortableBinaryInputArchive, PortableBinaryOutputArchive)
  serialize( Archive & ar, SizeTag<T> & t )
  {
    ar( t.size );
    portable_binary_detail::check_size( ar, t.size );
  }

  //! Saving binary data to portable binary
  template <class T> inline
  void save(PortableBinaryOutputArchive & ar, BinaryData<T> const & bd)
  {
    typedef typename std::remove_pointer<T>::type TT;
    static_assert( !std::is_floating_point<TT>::value ||
                   (std::is_floating_point<TT>::value && std::numeric_limits<TT>::is_iec559),
                   "Portable binary only supports IEEE 754 standardized floating point" );

    ar.saveBinary( bd.data, static_cast<std::size_t>( bd.size ) );
  }

  //! Loading binary data from portable binary
  template <class T> inline
  void load(PortableBinaryInputArchive & ar, BinaryData<T> & bd)
  {
    typedef typename std::remove_pointer<T>::type TT;
    static_assert( !std::is_floating_point<TT>::value ||
                   (std::is_floating_point<TT>::value && std::numeric_limits<TT>::is_iec559),
                   "Portable binary only supports IEEE 754 standardized floating point" );

    ar.template loadBinary<sizeof(TT)>( bd.data, static_cast<std::size_t>( bd.size ) );
  }
} // namespace cereal

// register archives for polymorphic support
CEREAL_REGISTER_ARCHIVE(cereal::PortableBinaryOutputArchive)
CEREAL_REGISTER_ARCHIVE(cereal::PortableBinaryInputArchive)

#endif // CEREAL_ARCHIVES_PORTABLE_BINARY_HPP_
