import assert from "node:assert/strict";
import { test } from "node:test";

import { pairAudioCards } from "../src/config/audio-cards.ts";

const pairedUsbFixture = {
  inputs: [{
    backend: "pulse" as const,
    direction: "input" as const,
    id: "alsa_input.usb-radio",
    label: "USB Audio CODEC",
    metadata: {
      vendorId: "1234",
      productId: "5678",
      deviceSerial: "SN42",
      alsaCard: "2",
    },
  }],
  outputs: [{
    backend: "pulse" as const,
    direction: "output" as const,
    id: "alsa_output.usb-radio",
    label: "USB Audio CODEC",
    metadata: { alsaCard: "2" },
  }],
};

test("prefers USB serial and pairs Pulse endpoints through ALSA identity", () => {
  assert.deepEqual(pairAudioCards(pairedUsbFixture), [{
    hardwareId: "usb:1234:5678:SN42",
    label: "USB Audio CODEC (SN42)",
    transport: "usb",
    complete: true,
    input: pairedUsbFixture.inputs[0],
    output: pairedUsbFixture.outputs[0],
  }]);
});

test("uses physical USB topology before stable ALSA card identity", () => {
  const cards = pairAudioCards({
    inputs: [{
      backend: "pulse" as const,
      direction: "input" as const,
      id: "input-a",
      label: "Codec A",
      metadata: { vendorId: "0d8c", productId: "0134", busPath: "1-2.3", alsaCard: "1" },
    }],
    outputs: [{
      backend: "alsa" as const,
      direction: "output" as const,
      id: "hw:1,0",
      label: "Codec A",
      metadata: { alsaCard: "1", alsaCardId: "CODEC" },
    }],
  });

  assert.deepEqual(cards[0]?.hardwareId, "usb:0d8c:0134:1-2.3");
  assert.equal(cards[0]?.complete, true);
});

test("excludes monitor sources and disambiguates duplicate serial-less cards", () => {
  const cards = pairAudioCards({
    inputs: [
      {
        backend: "pulse" as const,
        direction: "input" as const,
        id: "alsa_output.radio.monitor",
        label: "Radio Monitor",
        metadata: { alsaCard: "5" },
      },
      {
        backend: "pulse" as const,
        direction: "input" as const,
        id: "input-left",
        label: "USB Audio CODEC",
        metadata: { vendorId: "1234", productId: "5678", busPath: "1-2.1", alsaCard: "2" },
      },
      {
        backend: "pulse" as const,
        direction: "input" as const,
        id: "input-right",
        label: "USB Audio CODEC",
        metadata: { vendorId: "1234", productId: "5678", busPath: "1-2.2", alsaCard: "3" },
      },
    ],
    outputs: [],
  });

  assert.equal(cards.some((card) => card.input?.id.endsWith(".monitor")), false);
  assert.notEqual(cards[0]?.label, cards[1]?.label);
  assert.deepEqual(cards.map((card) => card.hardwareId), [
    "usb:1234:5678:1-2.1",
    "usb:1234:5678:1-2.2",
  ]);
});

test("reports an endpoint without stable metadata as incomplete and unknown", () => {
  assert.deepEqual(pairAudioCards({
    inputs: [{
      backend: "alsa",
      direction: "input",
      id: "hw:7,0",
      label: "Unnamed capture",
      metadata: { alsaCard: "7" },
    }],
    outputs: [],
  }), [{
    hardwareId: "unknown",
    label: "Unnamed capture",
    transport: "unknown",
    complete: false,
    input: {
      backend: "alsa",
      direction: "input",
      id: "hw:7,0",
      label: "Unnamed capture",
      metadata: { alsaCard: "7" },
    },
  }]);
});

test("does not emit a persistable card id from malformed identity metadata", () => {
  const [card] = pairAudioCards({
    inputs: [{
      backend: "pulse",
      direction: "input",
      id: "input-a",
      label: "USB Audio CODEC",
      metadata: {
        vendorId: "1234",
        productId: "5678",
        deviceSerial: "SN\n42",
        alsaCard: "2",
      },
    }],
    outputs: [{
      backend: "pulse",
      direction: "output",
      id: "output-a",
      label: "USB Audio CODEC",
      metadata: { alsaCard: "2" },
    }],
  });

  assert.deepEqual(card, {
    hardwareId: "unknown",
    label: "USB Audio CODEC",
    transport: "unknown",
    complete: false,
    input: {
      backend: "pulse",
      direction: "input",
      id: "input-a",
      label: "USB Audio CODEC",
      metadata: {
        vendorId: "1234",
        productId: "5678",
        deviceSerial: "SN\n42",
        alsaCard: "2",
      },
    },
    output: {
      backend: "pulse",
      direction: "output",
      id: "output-a",
      label: "USB Audio CODEC",
      metadata: { alsaCard: "2" },
    },
  });
});
