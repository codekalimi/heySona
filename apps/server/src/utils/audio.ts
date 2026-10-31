export function base64ToUint8Array(base64Value: string): Uint8Array {
  const binaryString = atob(base64Value);
  const bytes = new Uint8Array(binaryString.length);

  for (let byteIndex = 0; byteIndex < binaryString.length; byteIndex += 1) {
    bytes[byteIndex] = binaryString.charCodeAt(byteIndex);
  }

  return bytes;
}

export function pcm16MonoToWav(pcmAudio: Uint8Array, sampleRate: number): Uint8Array {
  const wavHeaderSize = 44;
  const wavAudio = new Uint8Array(wavHeaderSize + pcmAudio.length);
  const dataView = new DataView(wavAudio.buffer);
  const channelCount = 1;
  const bitsPerSample = 16;
  const byteRate = sampleRate * channelCount * bitsPerSample / 8;
  const blockAlign = channelCount * bitsPerSample / 8;

  writeAsciiString(dataView, 0, "RIFF");
  dataView.setUint32(4, 36 + pcmAudio.length, true);
  writeAsciiString(dataView, 8, "WAVE");
  writeAsciiString(dataView, 12, "fmt ");
  dataView.setUint32(16, 16, true);
  dataView.setUint16(20, 1, true);
  dataView.setUint16(22, channelCount, true);
  dataView.setUint32(24, sampleRate, true);
  dataView.setUint32(28, byteRate, true);
  dataView.setUint16(32, blockAlign, true);
  dataView.setUint16(34, bitsPerSample, true);
  writeAsciiString(dataView, 36, "data");
  dataView.setUint32(40, pcmAudio.length, true);
  wavAudio.set(pcmAudio, wavHeaderSize);

  return wavAudio;
}

function writeAsciiString(dataView: DataView, offset: number, value: string): void {
  for (let characterIndex = 0; characterIndex < value.length; characterIndex += 1) {
    dataView.setUint8(offset + characterIndex, value.charCodeAt(characterIndex));
  }
}
