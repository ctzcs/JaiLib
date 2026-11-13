#scope_file
core :: #import "thirdparty/onet/core" ;
#scope_export
// 有界协议字段；read_bytes 返回调用方拥有的副本，read_view 仅借用输入。



 //@region 有界字段

 MAX_PAYLOAD :: 4 * 1024 * 1024 ;
MAX_ITEMS :: 65536 ;

 fail :: ( r : * core . Reader ) {

 if r . err == . None {

 r . err = . Malformed ;

 }


}


write_count :: ( w : * core . Writer , n : int , limit : int = MAX_ITEMS ) {

 if n < 0 || n > limit {

 w . err = . Invalid_Count ;
return ;

 }

 core . write_uint32 ( w , ( cast , trunc ( u32 ) ( n ) ) , . Uncompressed ) ;

 }


read_count :: ( r : * core . Reader , limit : int = MAX_ITEMS ) -> int , bool {

 n := core . read_uint32 ( r , . Uncompressed ) ;
if r . err != . None || ( cast , trunc ( u64 ) ( n ) ) > ( cast , trunc ( u64 ) ( limit ) ) {

 fail ( r ) ;
return 0 , false ;

 }

 return ( cast ( int ) ( n ) ) , true ;

 }


write_bytes :: ( w : * core . Writer , data : [ ] u8 , limit : int = MAX_PAYLOAD ) {

 write_count ( w , ( data ) . count , limit ) ;
if w . err != . None {

 return ;

 }

 core . write_u8_array_as_bytes_unsafe ( w , data , . Loose ) ;

 }


read_bytes :: ( r : * core . Reader , limit : int = MAX_PAYLOAD ) -> [ ] u8 , bool {

 n , ok := read_count ( r , limit ) ;
if ! ok || n > core . reader_remaining_bits ( r ) / 8 {

 fail ( r ) ;
return .[ ] , false ;

 }

 data := new_slice ( u8 , n ) ;
i := 0 ; while i < n { defer i += 1 ;

 data [ i ] = core . read_uint8 ( r , . Uncompressed ) ;

 }

 if r . err != . None {

 release ( data ) ;
return .[ ] , false ;

 }

 return data , true ;

 }


read_view :: ( r : * core . Reader , limit : int = MAX_PAYLOAD ) -> [ ] u8 , bool {

 n , ok := read_count ( r , limit ) ;
if ! ok || r . bit_position % 8 != 0 || n > core . reader_remaining_bits ( r ) / 8 {

 fail ( r ) ;
return .[ ] , false ;

 }

 start := r . bit_position / 8 ;
r . bit_position += n * 8 ;
return view ( r . data , start , start + n ) , true ;

 }


finished :: ( r : * core . Reader ) -> bool {

 remaining := core . reader_remaining_bits ( r ) ;
if r . err != . None || remaining < 0 || remaining > 7 {

 return false ;

 }

 loop_index := 0 ; while loop_index < remaining { defer loop_index += 1 ;

 if core . read_bit ( r ) {

 return false ;

 }


}

 return r . err == . None ;

 }


clone :: ( data : [ ] u8 ) -> [ ] u8 {

 result := new_slice ( u8 , ( data ) . count ) ;
copy_samples ( result , data ) ;
return result ;

 }


equal :: ( a , b : [ ] u8 ) -> bool {

 if ( a ) . count != ( b ) . count {

 return false ;

 }

 for value , i : a {

 if value != b [ i ] {

 return false ;

 }


}

 return true ;

 }

 //@endregion


//@region 二进制增量

 // 在已经确认的、逐字节相同的基线上替换一个连续区间；读端先构建新值。

 write_delta :: ( w : * core . Writer , base , value : [ ] u8 ) {

 prefix := 0 ;
while prefix < min ( ( base ) . count , ( value ) . count ) && base [ prefix ] == value [ prefix ] {

 prefix += 1 ;

 }

 suffix := 0 ;
while suffix < min ( ( base ) . count , ( value ) . count ) - prefix && base [ ( base ) . count - 1 - suffix ] == value [ ( value ) . count - 1 - suffix ] {

 suffix += 1 ;

 }

 write_count ( w , prefix , MAX_PAYLOAD ) ;
write_count ( w , suffix , MAX_PAYLOAD ) ;
write_bytes ( w , view ( value , prefix , ( value ) . count - suffix ) ) ;

 }


read_delta :: ( r : * core . Reader , base : [ ] u8 ) -> [ ] u8 , bool {

 prefix , p_ok := read_count ( r , MAX_PAYLOAD ) ;
suffix , s_ok := read_count ( r , MAX_PAYLOAD ) ;
middle , m_ok := read_bytes ( r ) ;
defer release ( middle ) ;
if ! p_ok || ! s_ok || ! m_ok || prefix > ( base ) . count || suffix > ( base ) . count - prefix || prefix + suffix + ( middle ) . count > MAX_PAYLOAD {

 fail ( r ) ;
return .[ ] , false ;

 }

 result := new_slice ( u8 , prefix + ( middle ) . count + suffix ) ;
copy_samples ( view ( result , 0 , prefix ) , view ( base , 0 , prefix ) ) ;
copy_samples ( view ( result , prefix ) , middle ) ;
copy_samples ( view ( result , prefix + ( middle ) . count ) , view ( base , ( base ) . count - suffix ) ) ;
return result , true ;

 }

 //@endregion


// Cast semantics adapted. 
