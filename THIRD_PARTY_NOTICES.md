# Third-party acknowledgments and notices

myEq's original code and documentation are licensed under the MIT License in
[LICENSE](LICENSE). The material acknowledged below retains its own notices
and terms.

## Audio EQ Cookbook

The biquad coefficient calculations in `Sources/CDSP/DSP.cpp` are based on the
**Audio EQ Cookbook** equations by **Robert Bristow-Johnson**, as published in
the W3C Working Group Note of 8 June 2021, edited by **Raymond Toy**. The W3C
document was adapted from Robert Bristow-Johnson's `Audio-EQ-Cookbook.txt` with
permission.

Source: [Audio EQ Cookbook, 8 June 2021](https://www.w3.org/TR/2021/NOTE-audio-eq-cookbook-20210608/).

myEq implements the bell, shelf, and high-/low-pass equations in C++, normalizes
the coefficients, and applies its own parameter bounds and disabled-band
handling. This implementation was written for myEq in 2026; the acknowledgment
concerns these coefficient equations, not the entire audio engine.

This software includes material derived from the Audio EQ Cookbook linked
above. Copyright © 2021 W3C® (MIT, ERCIM, Keio, Beihang).

Original document notice: Copyright © 2021 W3C (World Wide Web Consortium)®
(MIT (Massachusetts Institute of Technology), ERCIM (European Research
Consortium for Informatics and Mathematics), Keio, Beihang).
W3C [liability](https://www.w3.org/Consortium/Legal/ipr-notice#Legal_Disclaimer),
[trademark](https://www.w3.org/Consortium/Legal/ipr-notice#W3C_Trademarks), and
[permissive document license](https://www.w3.org/copyright/software-license-2015/)
rules apply.

### W3C Software and Document License (2015)

License source: https://www.w3.org/copyright/software-license-2015/

This work is being provided by the copyright holders under the following license.

By obtaining and/or copying this work, you (the licensee) agree that you have read,
understood, and will comply with the following terms and conditions.

Permission to copy, modify, and distribute this work, with or without
modification, for any purpose and without fee or royalty is hereby granted,
provided that you include the following on ALL copies of the work or portions
thereof, including modifications:

- The full text of this NOTICE in a location viewable to users of the
  redistributed or derivative work.
- Any pre-existing intellectual property disclaimers, notices, or terms and
  conditions. If none exist, the [W3C Software and Document Short Notice](https://www.w3.org/Consortium/Legal/copyright-software-short-notice)
  should be included.
- Notice of any changes or modifications, through a copyright statement on the
  new code or document such as "This software or document includes material
  copied from or derived from [title and URI of the W3C document]. Copyright
  © [YEAR] W3C® (MIT, ERCIM, Keio, Beihang)."

THIS WORK IS PROVIDED "AS IS," AND COPYRIGHT HOLDERS MAKE NO REPRESENTATIONS OR
WARRANTIES, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO, WARRANTIES OF
MERCHANTABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF THE
SOFTWARE OR DOCUMENT WILL NOT INFRINGE ANY THIRD PARTY PATENTS, COPYRIGHTS,
TRADEMARKS OR OTHER RIGHTS.

COPYRIGHT HOLDERS WILL NOT BE LIABLE FOR ANY DIRECT, INDIRECT, SPECIAL OR
CONSEQUENTIAL DAMAGES ARISING OUT OF ANY USE OF THE SOFTWARE OR DOCUMENT.

The name and trademarks of copyright holders may NOT be used in advertising or
publicity pertaining to the work without specific, written prior permission.
Title to copyright in this work will at all times remain with copyright holders.
