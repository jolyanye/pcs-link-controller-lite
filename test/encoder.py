class Encoder8b10b:
    def __init__(self):
        self.rd = 0  # 0 = Negative (RD-), 1 = Positive (RD+)
        self.lut_5b6b = {
            0: ("100111", "011000", True),  1: ("011101", "100010", True),
            2: ("101101", "010010", True),  3: ("110001", "110001", False),
            4: ("110101", "001010", True),  5: ("101001", "101001", False),
            6: ("011001", "011001", False), 7: ("111000", "000111", True),
            8: ("111001", "000110", True),  9: ("100101", "100101", False),
            10:("010101", "010101", False), 11:("110100", "110100", False),
            12:("001101", "001101", False), 13:("101100", "101100", False),
            14:("011100", "011100", False), 15:("010111", "101000", True),
            16:("011011", "100100", True),  17:("100011", "100011", False),
            18:("010011", "010011", False), 19:("110010", "110010", False),
            20:("001011", "001011", False), 21:("101010", "101010", False),
            22:("011010", "011010", False), 23:("111010", "000101", True),
            24:("110011", "001100", True),  25:("100110", "100110", False),
            26:("010110", "010110", False), 27:("110110", "001001", True),
            28:("001110", "001110", False), 29:("101110", "010001", True),
            30:("011110", "100001", True),  31:("101011", "010100", True)
        }
        self.lut_3b4b = {
            0: ("1011", "0100", True),  1: ("1001", "1001", False),
            2: ("0101", "0101", False), 3: ("1100", "0011", True),
            4: ("1101", "0010", True),  5: ("1010", "1010", False),
            6: ("0110", "0110", False)
        }
    
    def encode(self, byte_val):
        val5 = byte_val & 0x1F
        val3 = (byte_val >> 5) & 0x07
        
        rd_minus_6b, rd_plus_6b, flips_6b = self.lut_5b6b[val5]
        str_6b = rd_minus_6b if self.rd == 0 else rd_plus_6b
        rd_mid = (1 - self.rd) if flips_6b else self.rd
        
        if val3 == 7:
            str_4b = "1110" if rd_mid == 0 else "0001"
            flips_4b = True
        else:
            rd_minus_4b, rd_plus_4b, flips_4b = self.lut_3b4b[val3]
            str_4b = rd_minus_4b if rd_mid == 0 else rd_plus_4b
            
        self.rd = (1 - rd_mid) if flips_4b else rd_mid
        
        bits_6b = [int(str_6b[5-i]) for i in range(6)]
        bits_4b = [int(str_4b[3-i]) for i in range(4)]
        
        return bits_6b + bits_4b