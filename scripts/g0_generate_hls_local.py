import hashlib,json,pathlib,shutil,struct,subprocess
root=pathlib.Path("G0F09C")
root.mkdir(exist_ok=True)
def run(args):
    return subprocess.check_output(args,timeout=90)
def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
ff=shutil.which("ffmpeg");probe=shutil.which("ffprobe")
manifest={"ffmpeg":run([ff,"-version"]).decode(),"ffprobe":run([probe,"-version"]).decode(),"packages":run(["dpkg-query","-W","ffmpeg"]).decode(),"exe_sha256":{x:sha(pathlib.Path(x)) for x in (ff,probe)},"fixtures":[]}
# One encode, remux the same AAC stream into both segment types.
src=root/"source.s16"
vals=[((i*104729+12345)&0xffff)-32768 for i in range(48000*2*4)]
src.write_bytes(struct.pack("<"+"h"*len(vals),*vals))
encoded=root/"source.m4a"
run([ff,"-nostdin","-v","error","-y","-f","s16le","-ar","48000","-ac","2","-i",str(src),"-c:a","aac","-b:a","128k",str(encoded)])
for mode,ext in [("mpegts","ts"),("fmp4","m4s")]:
    dest=root/(mode+".m3u8")
    args=[ff,"-nostdin","-v","error","-y","-i",str(encoded),"-map","0:a:0","-c","copy","-f","hls","-hls_time","1","-hls_list_size","0","-hls_playlist_type","vod","-hls_segment_type",mode,"-hls_segment_filename",str(root/(mode+"-%03d."+ext))]
    if mode=="fmp4":args+=["-hls_fmp4_init_filename","init.mp4"]
    run(args+[str(dest)])
    lines=dest.read_text().splitlines()
    segments=[x for x in lines if x and not x.startswith("#")]
    assert 3<=len(segments)<=6 and "#EXT-X-ENDLIST" in lines
    assert all(pathlib.Path(x).name==x and (root/x).is_file() for x in segments)
    files=[dest.name]+segments+(["init.mp4"] if mode=="fmp4" else [])
    assert all((root/x).is_file() for x in files)
    info=json.loads(run([probe,"-v","error","-show_format","-show_streams","-show_packets","-show_data_hash","sha256","-of","json",str(dest)]))
    streams=info["streams"]
    assert len(streams)==1 and streams[0]["codec_name"]=="aac" and streams[0]["codec_type"]=="audio",streams
    assert int(streams[0]["sample_rate"])==48000 and streams[0]["channels"]==2
    assert info["format"]["format_name"]=="hls",info["format"]
    packets=info["packets"]
    assert 0<len(packets)<2048
    manifest["fixtures"].append({"file":dest.name,"format":"hls","codec":"aac","sha256":sha(dest),"segments":len(segments),"files":{x:sha(root/x) for x in files},"host_packets":[{"size":int(x["size"]),"sha256":x["data_hash"].split(":")[1].lower()} for x in packets],"host_format":info["format"],"host_stream":streams[0]})
    print("G0_F09C_FIXTURE",mode,"segments",len(segments),"packets",len(packets),"playlistHash",sha(dest))
manifest["source_sha256"]=sha(src)
manifest["encoded_sha256"]=sha(encoded)
src.unlink();encoded.unlink()
(root/"manifest.json").write_text(json.dumps(manifest,indent=2))
