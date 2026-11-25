import hashlib,json,pathlib,shutil,struct,subprocess,tempfile
root=pathlib.Path("G0F08E")
def run(args):
    return subprocess.check_output(args,timeout=90)
def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
ff=shutil.which("ffmpeg")
probe=shutil.which("ffprobe")
manifest={"ffmpeg":run([ff,"-version"]).decode(),"ffprobe":run([probe,"-version"]).decode(),"packages":run(["dpkg-query","-W","ffmpeg"]).decode(),"exe_sha256":{x:sha(pathlib.Path(x)) for x in (ff,probe)},"fixtures":{}}
with tempfile.TemporaryDirectory() as tmp:
    src=pathlib.Path(tmp)/"source.s32"
    for codec,mux,ext,rates in [("pcm_bluray","mpegts","m2ts",[48000,96000,192000]),("pcm_dvd","dvd","vob",[48000,96000])]:
        for rate in rates:
            for n in (10080,10082):
                ch=2
                vals=[((i*104729+12345)&0xffffff)-0x800000 for i in range(n*ch)]
                assert len({v&255 for v in vals})==256
                raw=struct.pack("<"+"i"*len(vals),*(v<<8 for v in vals))
                src.write_bytes(raw)
                name=f"{codec}-{rate}-{ch}-24-{n}"
                dest=root/f"{name}.{ext}"
                ref=root/f"{name}.f32"
                args=[ff,"-nostdin","-v","error","-y","-f","s32le","-ar",str(rate),"-ac",str(ch),"-i",str(src),"-map_metadata","-1","-c:a",codec,"-sample_fmt","s32","-bits_per_raw_sample","24"]
                if codec=="pcm_bluray":args+=["-mpegts_m2ts_mode","1"]
                args+=["-f",mux,str(dest)]
                run(args)
                info=json.loads(run([probe,"-v","error","-select_streams","a","-show_streams","-of","json",str(dest)]))["streams"]
                assert len(info)==1 and info[0]["codec_name"]==codec and int(info[0]["sample_rate"])==rate and info[0]["channels"]==ch and int(info[0].get("bits_per_raw_sample",0))==24,info
                run([ff,"-nostdin","-v","error","-y","-i",str(dest),"-map","0:a:0","-c:a","pcm_f32le","-f","f32le",str(ref)])
                expected=((n+359)//360)*360 if codec=="pcm_bluray" else n
                oracle=struct.pack("<"+"f"*len(vals),*(v/8388608 for v in vals))+bytes((expected-n)*ch*4)
                assert ref.read_bytes()==oracle,(name,ref.stat().st_size,expected*ch*4)
                manifest["fixtures"][name]={"encoded_sha256":sha(dest),"reference_sha256":sha(ref),"source_s32_sha256":hashlib.sha256(raw).hexdigest(),"oracle_sha256":hashlib.sha256(oracle).hexdigest(),"source_frames":n,"host_frames":expected,"zero_padded_frames":expected-n,"source_low_byte_distinct":256,"stream":info[0],"encoder_args":args[1:]}
                print("G0_F08E_FIXTURE",name,sha(dest),sha(ref),"sourceFrames",n,"hostFrames",expected,"zeroPadding",expected-n,"oracleExact",True)
assert len(manifest["fixtures"])==10
(root/"manifest.json").write_text(json.dumps(manifest,indent=2))
