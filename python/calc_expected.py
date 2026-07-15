import numpy as np

# A matrix: A[i][k] = (i+1)*10 + (k+1)
A = np.zeros((8, 8), dtype=np.int32)
for i in range(8):
    for k in range(8):
        A[i][k] = (i + 1) * 10 + (k + 1)

# Test 1 Weight matrix: Identity
W1 = np.eye(8, dtype=np.int32)
C1 = A @ W1

# Test 2 Weight matrix: All ones
W2 = np.ones((8, 8), dtype=np.int32)
C2 = A @ W2

# Test 3 Weight matrix: W3[k][j] = k + j
W3 = np.zeros((8, 8), dtype=np.int32)
for k in range(8):
    for j in range(8):
        W3[k][j] = k + j
C3 = A @ W3

print("--- A Matrix ---")
print(A)
print("\n--- C1 (Identity) ---")
print(C1)
print("\n--- C2 (All ones) ---")
print(C2)
print("\n--- C3 (Ramp k+j) ---")
print(C3)

# Print C3 in Verilog initialization format
print("\nVerilog initialization for C3:")
for i in range(8):
    for j in range(8):
        print(f"expected_C3[{i}][{j}] = 32'sd{C3[i][j]};")
