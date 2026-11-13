#scope_file
CryptoTest :: #import "thirdparty/onet/transport/crypto";
#scope_export
crypto_hex :: (digest:[32]u8) -> [64]u8 {
 text:[64]u8; digits:="0123456789abcdef";
 for b,i:digest { text[2*i]=digits[b>>4]; text[2*i+1]=digits[b&15]; }
 return text;
}
onet_sha256_hmac_known_answers :: (t:*Test) {
{ bytes:=new_slice(u8,0); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"); }
{ bytes:=new_slice(u8,1); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"); }
{ bytes:=new_slice(u8,55); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59"); }
{ bytes:=new_slice(u8,56); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562"); }
{ bytes:=new_slice(u8,63); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488"); }
{ bytes:=new_slice(u8,64); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108"); }
{ bytes:=new_slice(u8,65); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781"); }
{ bytes:=new_slice(u8,127); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"92ca0fa6651ee2f97b884b7246a562fa71250fedefe5ebf270d31c546bfea976"); }
{ bytes:=new_slice(u8,128); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"471fb943aa23c511f6f72f8d1652d9c880cfa392ad80503120547703e56a2be5"); }
{ bytes:=new_slice(u8,257); defer release(bytes); for *b,i:bytes b.*=cast,trunc(u8)i; digest:=CryptoTest.sha256(string.{bytes.count,bytes.data}); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"54acfbfedc4d8da40f76f275e1a98f10af8ef1fb9fb39e5a67a00aabcbe6597c"); }
{ key:=new_slice(u8,20); defer release(key); for *b:key b.*=0x0b; digest:=CryptoTest.hmac_sha256(string.{key.count,key.data},"Hi There"); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"); }
{ key:=new_slice(u8,64); defer release(key); for *b:key b.*=0x0b; digest:=CryptoTest.hmac_sha256(string.{key.count,key.data},"Hi There"); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"21cd586aeca0579d99a1c938127c92525a371f807bc5ba6eb78bc825bd4f2be3"); }
{ key:=new_slice(u8,65); defer release(key); for *b:key b.*=0x0b; digest:=CryptoTest.hmac_sha256(string.{key.count,key.data},"Hi There"); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"727b82fba264393c5d67fd6d6ad783e9019a1fa6a857fccb70f5852f04be5d5d"); }
{ key:=new_slice(u8,131); defer release(key); for *b:key b.*=0x0b; digest:=CryptoTest.hmac_sha256(string.{key.count,key.data},"Hi There"); hex:=crypto_hex(digest); expect_value(t,string.{64,hex.data},"03f731975a2104815e7a646158f58799eb40a54f41c0243d1540e8d2517a13cb"); }
bytes:[32]u8; expect(t,CryptoTest.random_bytes(bytes)); any:bool; for b:bytes any=any || b!=0; expect(t,any);
}
