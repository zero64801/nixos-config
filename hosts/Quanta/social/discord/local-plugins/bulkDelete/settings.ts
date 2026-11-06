import { definePluginSettings } from "@api/Settings";
import { OptionType } from "@utils/types";

export const settings = definePluginSettings({
    delay: {
        type: OptionType.NUMBER,
        description: "Typical milliseconds between two deletions",
        default: 1500,
        isValid: (value: number) => value >= 0 || "Must be 0 or more"
    },
    variation: {
        type: OptionType.NUMBER,
        description: "How much each wait strays from the typical delay, in percent",
        default: 40,
        isValid: (value: number) => (value >= 0 && value <= 100) || "Must be between 0 and 100"
    },
    breaks: {
        type: OptionType.BOOLEAN,
        description: "Now and then wait a few seconds longer, like someone scrolling or looking away",
        default: true
    }
});
