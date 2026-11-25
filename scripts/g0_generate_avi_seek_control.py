"""Generate position-unique AVI PCM control without changing its container or index."""
import hashlib,json,pathlib,struct,sys
root=pathlib.Path(sys.argv[1])
src=root/"avi.avi"
original=src.read_bytes()
assert hashlib.sha256(original).hexdigest()=="23c559ae77c50679fdbc21bff2b515dfce1a0da8cad1bf47cc4630f281ca2f13"
assert original[:4]==b"RIFF" and original[8:12]==b"AVI "
assert 8+struct.unpack_from("<I",original,4)[0]==len(original)
control=bytearray(original)
chunks=[]
def walk(start,end,in_movi=False):
    pos=start
    while pos+8<=end:
        tag=original[pos:pos+4]
        size=struct.unpack_from("<I",original,pos+4)[0]
        data=pos+8
        stop=data+size
        assert stop<=end
        if tag==b"LIST":
            assert size>=4
            walk(data+4,stop,in_movi or original[data:data+4]==b"movi")
        elif in_movi and tag==b"00wb":
            assert size%4==0 and size>0
            # SHA256 counter stream, unique chunk coordinates, reproducible PCM bytes.
            stream=b"".join(hashlib.sha256(struct.pack("<QQ",data,i)).digest() for i in range((size+31)//32))[:size]
            control[data:stop]=stream
            chunks.append({"header":pos,"data":data,"size":size,"original_sha256":hashlib.sha256(original[data:stop]).hexdigest(),"control_sha256":hashlib.sha256(stream).hexdigest()})
        pos=stop+(size&1)
    assert pos==end,(pos,end)
walk(12,len(original))
assert chunks and sum(c["size"] for c in chunks)==192000
assert len({c["control_sha256"] for c in chunks})==len(chunks)
# Verify restoring only the recorded payload ranges gives byte-identical container.
restored=bytearray(control)
for c in chunks:
    p=c["data"];n=c["size"];restored[p:p+n]=original[p:p+n]
assert restored==original
(root/"avi-unique.avi").write_bytes(control)
manifest={"original_sha256":hashlib.sha256(original).hexdigest(),"control_sha256":hashlib.sha256(control).hexdigest(),"chunks":chunks}
(root/"avi-control.json").write_text(json.dumps(manifest,indent=2))
print("G0_F09D1_GENERATE chunks=%d bytes=%d original=%s control=%s"%(len(chunks),sum(c["size"] for c in chunks),manifest["original_sha256"],manifest["control_sha256"]))
