import hashlib,json,pathlib,shutil,struct,subprocess
root=pathlib.Path("G0F09B")
root.mkdir(exist_ok=True)
def run(args):
    return subprocess.check_output(args,timeout=90)
def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
ff=shutil.which("ffmpeg");probe=shutil.which("ffprobe")
manifest={"ffmpeg":run([ff,"-version"]).decode(),"ffprobe":run([probe,"-version"]).decode(),"packages":run(["dpkg-query","-W","ffmpeg"]).decode(),"exe_sha256":{x:sha(pathlib.Path(x)) for x in (ff,probe)},"fixtures":[]}
# Exact original stereo PCM, one second at48k; no third-party audio.
src=root/"source.s16"
vals=[((i*104729+12345)&0xffff)-32768 for i in range(48000*2)]
src.write_bytes(struct.pack("<"+"h"*len(vals),*vals))
profiles=[("dts","dts","dca","dts"),("truehd","truehd","truehd","truehd"),("avi","avi","pcm_s16le","pcm_s16le")]
for name,fmt,enc,codec in profiles:
    dest=root/(name+"."+name)
    run([ff,"-nostdin","-v","error","-y","-f","s16le","-ar","48000","-ac","2","-i",str(src),"-map_metadata","-1","-metadata","title=Apolo G0 synthetic","-c:a",enc,"-strict","-2","-f",fmt,str(dest)])
    renamed=root/(name+".bin")
    shutil.copyfile(dest,renamed)
    for p in (dest,renamed):
        info=json.loads(run([probe,"-v","error","-show_format","-show_streams","-show_packets","-show_data_hash","sha256","-of","json",str(p)]))
        streams=info["streams"]
        assert len(streams)==1 and streams[0]["codec_name"]==codec and streams[0]["codec_type"]=="audio",streams
        assert int(streams[0]["sample_rate"])==48000 and streams[0]["channels"]==2
        assert info["format"]["format_name"]==fmt,info["format"]
        packets=info["packets"]
        assert 0<len(packets)<2048
        record={"file":p.name,"format":fmt,"codec":codec,"sha256":sha(p),"host_packets":[{"size":int(x["size"]),"sha256":x["data_hash"].split(":")[1].lower()} for x in packets],"host_format":info["format"],"host_stream":streams[0]}
        manifest["fixtures"].append(record)
        print("G0_F09B_FIXTURE",p.name,fmt,codec,len(packets),sha(p))
    assert manifest["fixtures"][-1]["host_packets"]==manifest["fixtures"][-2]["host_packets"]
manifest["source_sha256"]=sha(src)
src.unlink()
(root/"manifest.json").write_text(json.dumps(manifest,indent=2))
