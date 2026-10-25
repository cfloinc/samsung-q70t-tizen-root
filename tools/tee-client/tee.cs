using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// NIKEM (Q70T, Tizen 6.0) SWU TrustZone firmware decrypt client.
//
// Legacy (Tizen 6) TEEC ABI:
//   TEEC_Operation  60 bytes = started(4) paramTypes(4) params[4](12 each) imp(4)
//   TEEC_Parameter  12 bytes (memref = {parent,size,offset}, value = {a,b,pad})
//   paramTypes      t0 | t1<<8 | t2<<16 | t3<<24
//   memref types    0x0F (PARTIAL_INOUT) for both directions
//
// Two modes, selected by which input files exist in the profctl dir:
//   TOC:     toc.bin                    (salt fixed 9cdd28651baf3f28)
//   SECTION: section.bin + salt.bin      (8 raw bytes)
//
// Output is written to profctl/profctl_tee<toc|section>.log, which matches the
// sdb pull whitelist (profctl_[a-zA-Z]{1,30}.log).
internal static class TeeProbe
{
    const string LIB = "/usr/lib/libteec.so";
    const string PASS = "/usr/share/org.tizen.tv.swu/itemsAESPassphraseEncrypted.txt";
    const string D = "/opt/usr/home/owner/share/tmp/sdk_tools/profctl/";
    const string STATUS = D + "profctl_teestatus.log";
    const string TOCIN = D + "toc.bin";
    const string SECIN = D + "section.bin";
    const string SALTIN = D + "salt.bin";
    const string TOCOUT = D + "profctl_teetoc.log";
    const string SECOUT = D + "profctl_teesection.log";

    const uint TEEC_LOGIN_PUBLIC = 0;
    const uint T_PARTIAL_INOUT = 0x0F;
    const uint T_VALUE_INPUT = 0x01;
    const uint T_VALUE_OUTPUT = 0x02;
    const uint T_NONE = 0x00;

    const int SHM_SIZE = 0x10000;
    const int CHUNK = 0x10000;

    static readonly byte[] SWU_UUID = new byte[16] {
        0x21,0x22,0x22,0x22, 0x00,0x00, 0x00,0x00,
        0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01
    };

    static readonly byte[] TOC_SALT = { 0x9c,0xdd,0x28,0x65,0x1b,0xaf,0x3f,0x28 };

    [DllImport(LIB, EntryPoint = "TEEC_InitializeContext")] static extern uint TEEC_InitializeContext(IntPtr name, IntPtr ctx);
    [DllImport(LIB, EntryPoint = "TEEC_FinalizeContext")] static extern void TEEC_FinalizeContext(IntPtr ctx);
    [DllImport(LIB, EntryPoint = "TEEC_AllocateSharedMemory")] static extern uint TEEC_AllocateSharedMemory(IntPtr ctx, IntPtr shm);
    [DllImport(LIB, EntryPoint = "TEEC_ReleaseSharedMemory")] static extern void TEEC_ReleaseSharedMemory(IntPtr shm);
    [DllImport(LIB, EntryPoint = "TEEC_OpenSession")] static extern uint TEEC_OpenSession(IntPtr ctx, IntPtr session, byte[] uuid, uint login, IntPtr connData, IntPtr op, out uint origin);
    [DllImport(LIB, EntryPoint = "TEEC_CloseSession")] static extern void TEEC_CloseSession(IntPtr session);
    [DllImport(LIB, EntryPoint = "TEEC_InvokeCommand")] static extern uint TEEC_InvokeCommand(IntPtr session, uint cmd, IntPtr op, out uint origin);

    static StringBuilder L = new StringBuilder();
    static IntPtr ctx, sess, shmIn, shmOut, shmSalt, op;
    static uint origin;

    public static int Main(string[] args)
    {
        try { Run(); }
        catch (Exception e) { Log("EXCEPTION " + e); }
        Flush();
        return 0;
    }

    static void Run()
    {
        Log("=== NIKEM TEEC decrypt v2 ===");
        bool section = File.Exists(SECIN);
        string input = section ? SECIN : TOCIN;
        byte[] salt = section ? File.ReadAllBytes(SALTIN) : TOC_SALT;
        if (!File.Exists(input)) { Log("no input at " + input); return; }
        if (salt.Length != 8) { Log("bad salt length " + salt.Length); return; }

        var pass = File.ReadAllBytes(PASS);
        var data = File.ReadAllBytes(input);
        // Layout sanity: catching these early avoids the classic 0x8C-shifted
        // ciphertext, which decrypts to garbage while every call returns rc=0.
        if (!section && data.Length != 3984)
            Log("WARN toc.bin is " + data.Length + " bytes; MSDU11 on this family is 3984");
        if (section && (data.Length % 16) != 0)
            Log("WARN section ciphertext is not AES-block-aligned (" + data.Length + " bytes)");
        Log("mode=" + (section ? "SECTION" : "TOC") + " input=" + data.Length
            + " salt=" + BitConverter.ToString(salt));
        if (data.Length % 16 != 0) { Log("input not AES aligned"); return; }

        ctx = Marshal.AllocHGlobal(64); sess = Marshal.AllocHGlobal(64);
        shmIn = Marshal.AllocHGlobal(64); shmOut = Marshal.AllocHGlobal(64);
        shmSalt = Marshal.AllocHGlobal(64); op = Marshal.AllocHGlobal(64);
        Z(ctx, 64); Z(sess, 64); Z(shmIn, 64); Z(shmOut, 64); Z(shmSalt, 64); Z(op, 64);

        uint rc = TEEC_InitializeContext(IntPtr.Zero, ctx);
        Log("InitializeContext rc=0x" + H(rc));
        if (rc != 0) return;
        if (Alloc(shmIn) != 0 || Alloc(shmOut) != 0 || Alloc(shmSalt) != 0) return;

        rc = TEEC_OpenSession(ctx, sess, SWU_UUID, TEEC_LOGIN_PUBLIC, IntPtr.Zero, IntPtr.Zero, out origin);
        Log("OpenSession rc=0x" + H(rc) + " origin=0x" + H(origin));
        if (rc != 0) return;

        // cmd 0: init
        Z(op, 60);
        Types(op, T_PARTIAL_INOUT, T_PARTIAL_INOUT, T_VALUE_INPUT, T_VALUE_INPUT);
        Put(shmIn, pass);
        Mem(op, 0, shmIn, pass.Length);
        Put(shmSalt, salt);
        Mem(op, 1, shmSalt, salt.Length);
        Val(op, 2, 0, 1);
        Val(op, 3, 1, 1 + (2 << 8));
        rc = TEEC_InvokeCommand(sess, 0, op, out origin);
        Log("cmd0(init) rc=0x" + H(rc) + " origin=0x" + H(origin));
        if (rc != 0) return;

        // cmd 1 in CHUNK-sized pieces, hold back one AES block
        var output = new MemoryStream();
        byte[] pending = new byte[0];
        int pos = 0;
        int chunks = 0;
        while (pos < data.Length)
        {
            int n = Math.Min(CHUNK, data.Length - pos);
            uint crc = Crc32(data, pos, n);
            byte[] chunk = new byte[n];
            Buffer.BlockCopy(data, pos, chunk, 0, n);
            pos += n; chunks++;

            Z(op, 60);
            Types(op, T_PARTIAL_INOUT, T_PARTIAL_INOUT, T_VALUE_OUTPUT, T_NONE);
            Put(shmIn, chunk);
            Mem(op, 0, shmIn, n);
            Zb(shmOut);
            Mem(op, 1, shmOut, SHM_SIZE);
            rc = TEEC_InvokeCommand(sess, 1, op, out origin);
            int outLen = Marshal.ReadInt32(op, 8 + 2 * 12);
            if (rc != 0) { Log("cmd1 chunk " + chunks + " rc=0x" + H(rc) + " origin=0x" + H(origin) + " outLen=" + outLen); return; }
            byte[] got = Get(shmOut, outLen);
            byte[] comb = new byte[pending.Length + got.Length];
            Buffer.BlockCopy(pending, 0, comb, 0, pending.Length);
            Buffer.BlockCopy(got, 0, comb, pending.Length, got.Length);
            int emit = comb.Length > 16 ? comb.Length - 16 : 0;
            if (emit > 0) output.Write(comb, 0, emit);
            pending = new byte[comb.Length - emit];
            Buffer.BlockCopy(comb, emit, pending, 0, pending.Length);
            if (chunks < 3 || pos >= data.Length) Log("  chunk " + chunks + " in=" + n + " out=" + outLen + " pending=" + pending.Length);
        }

        // cmd 2: finalize
        Z(op, 60);
        Types(op, T_PARTIAL_INOUT, T_VALUE_OUTPUT, T_NONE, T_NONE);
        Zb(shmOut);
        Mem(op, 0, shmOut, SHM_SIZE);
        rc = TEEC_InvokeCommand(sess, 2, op, out origin);
        int finLen = Marshal.ReadInt32(op, 8 + 1 * 12);
        Log("cmd2(finalize) rc=0x" + H(rc) + " origin=0x" + H(origin) + " finLen=" + finLen);
        if (rc != 0) return;

        byte[] tail = finLen > 0 ? Get(shmOut, finLen) : new byte[0];
        byte[] fin = new byte[pending.Length + tail.Length];
        Buffer.BlockCopy(pending, 0, fin, 0, pending.Length);
        Buffer.BlockCopy(tail, 0, fin, pending.Length, tail.Length);
        int pad = fin.Length > 0 ? fin[fin.Length - 1] : 0;
        bool goodPad = pad >= 1 && pad <= 16;
        if (goodPad) for (int i = fin.Length - pad; i < fin.Length; i++) if (fin[i] != pad) { goodPad = false; break; }
        if (goodPad) output.Write(fin, 0, fin.Length - pad);
        else { output.Write(fin, 0, fin.Length); Log("WARN bad PKCS7 pad=" + pad + " (check toc length 3984 and section offset 0x108C)"); }

        byte[] all = output.ToArray();
        Log("plain total=" + all.Length + " pad=" + pad + " padOK=" + goodPad
            + " crc32=0x" + Crc32(all, 0, all.Length).ToString("x8"));
        Log("first32=" + BitConverter.ToString(all, 0, Math.Min(32, all.Length)));
        if (!section)
            Log("tree-magic-offset=" + IndexOf(all, Encoding.ASCII.GetBytes("Tizen Software")));

        File.WriteAllBytes(section ? SECOUT : TOCOUT, all);
        Log("wrote " + (section ? SECOUT : TOCOUT));

        TEEC_CloseSession(sess);
        TEEC_FinalizeContext(ctx);
        Log("done");
    }

    static uint Alloc(IntPtr shm)
    {
        Marshal.WriteInt32(shm, 4, SHM_SIZE);
        Marshal.WriteInt32(shm, 8, 3);
        uint rc = TEEC_AllocateSharedMemory(ctx, shm);
        if (rc != 0) Log("AllocSharedMemory rc=0x" + H(rc));
        return rc;
    }

    static void Types(IntPtr o, uint a, uint b, uint c, uint d)
    {
        uint v = (a & 0xFF) | ((b & 0xFF) << 8) | ((c & 0xFF) << 16) | ((d & 0xFF) << 24);
        Marshal.WriteInt32(o, 4, unchecked((int)v));
    }
    static void Mem(IntPtr o, int i, IntPtr shm, int size)
    {
        int off = 8 + i * 12;
        Marshal.WriteIntPtr(o, off, shm);
        Marshal.WriteInt32(o, off + 4, size);
        Marshal.WriteInt32(o, off + 8, 0);
    }
    static void Val(IntPtr o, int i, uint a, uint b)
    {
        int off = 8 + i * 12;
        Marshal.WriteInt32(o, off, unchecked((int)a));
        Marshal.WriteInt32(o, off + 4, unchecked((int)b));
        Marshal.WriteInt32(o, off + 8, 0);
    }
    static void Put(IntPtr shm, byte[] data)
    {
        IntPtr buf = Marshal.ReadIntPtr(shm, 0);
        if (data.Length > Marshal.ReadInt32(shm, 4)) throw new Exception("too big");
        Marshal.Copy(data, 0, buf, data.Length);
    }
    static byte[] Get(IntPtr shm, int len)
    {
        if (len < 0 || len > SHM_SIZE) throw new Exception("bad len " + len);
        IntPtr buf = Marshal.ReadIntPtr(shm, 0);
        byte[] b = new byte[len];
        Marshal.Copy(buf, b, 0, len);
        return b;
    }
    static void Zb(IntPtr shm)
    {
        IntPtr buf = Marshal.ReadIntPtr(shm, 0);
        for (int i = 0; i < SHM_SIZE; i += 4) Marshal.WriteInt32(buf, i, 0);
    }
    static void Z(IntPtr p, int n) { for (int i = 0; i < n; i++) Marshal.WriteByte(p, i, 0); }

    static int IndexOf(byte[] hay, byte[] needle)
    {
        for (int i = 0; i + needle.Length <= hay.Length; i++)
        {
            int j = 0; while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return i;
        }
        return -1;
    }

    static uint[] _crcTable;
    static uint Crc32(byte[] data, int off, int len)
    {
        if (_crcTable == null)
        {
            _crcTable = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint c = i;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                _crcTable[i] = c;
            }
        }
        uint crc = 0xFFFFFFFFu;
        for (int i = 0; i < len; i++) crc = _crcTable[(crc ^ data[off + i]) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    static string H(uint v) { return v.ToString("x8", CultureInfo.InvariantCulture); }
    static void Log(string s) { L.Append(s).Append('\n'); try { Console.Error.WriteLine("[tee] " + s); } catch { } }
    static void Flush()
    {
        try { File.WriteAllText(STATUS, L.ToString()); } catch { }
        try { File.AppendAllText("/home/owner/share/tmp/sdk_tools/tee.log", L.ToString()); } catch { }
    }
}
