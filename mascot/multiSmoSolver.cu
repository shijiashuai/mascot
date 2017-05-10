//
// Created by ss on 16-12-14.
//

#include "multiSmoSolver.h"
#include "../svm-shared/constant.h"
#include "cuda_runtime.h"
#include "trainingFunction.h"
#include "../svm-shared/smoGPUHelper.h"
#include "../svm-shared/HessianIO/deviceHessianOnFly.h"

void MultiSmoSolver::solve() {
    initCache(CACHE_SIZE);
    int nrClass = problem.getNumOfClasses();
    //train nrClass*(nrClass-1)/2 binary models
    int k = 0;
    for (int i = 0; i < nrClass; ++i) {
        for (int j = i + 1; j < nrClass; ++j) {
            printf("training classifier with label %d and %d\n", i, j);
            SvmProblem subProblem = problem.getSubProblem(i, j);
            init4Training(subProblem);
            int maxIter = (subProblem.getNumOfSamples() > INT_MAX / ITERATION_FACTOR
                           ? INT_MAX
                           : ITERATION_FACTOR * subProblem.getNumOfSamples()) * 4;
            int numOfIter;
            for (numOfIter = 0; numOfIter < maxIter && !iterate(subProblem); numOfIter++) {
                if (numOfIter % 1000 == 0 && numOfIter != 0) {
                    std::cout << ".";
                    std::cout.flush();
                }
            }

            cout << "# of iteration: " << numOfIter << endl;
            vector<int> svIndex;
            vector<float_point> coef;
            float_point rho;
            extractModel(subProblem, svIndex, coef, rho);
            model.addBinaryModel(subProblem, svIndex,coef, rho, i, j);
            k++;
            deinit4Training();
        }
    }
}

void MultiSmoSolver::initCache(int cacheSize) {
//    gpuCache = new CLATCache(cacheSize);

}

bool MultiSmoSolver::iterate(SvmProblem &subProblem) {
    int trainingSize = subProblem.getNumOfSamples();
    GetBlockMinYiGValue << < gridSize, BLOCK_SIZE >> > (devYiGValue, devAlpha, devLabel, param.C,
            trainingSize, devBlockMin, devBlockMinGlobalKey);
    //global reducer
    GetGlobalMin << < 1, BLOCK_SIZE >> >
                         (devBlockMin, devBlockMinGlobalKey, numOfBlock, devYiGValue, NULL, devBuffer);

    //copy result back to host
    checkCudaErrors(cudaMemcpy(hostBuffer, devBuffer, sizeof(float_point) * 2, cudaMemcpyDeviceToHost));
    int m_nIndexofSampleOne = (int) hostBuffer[0];
    float_point fMinValue;
    fMinValue = hostBuffer[1];
    float_point *devHessianSampleRow1 = devHessianMatrixCache + getHessianRow(m_nIndexofSampleOne);

    //lock cached entry for the sample one, in case it is replaced by sample two
    gpuCache->LockCacheEntry(m_nIndexofSampleOne);

    float_point fUpSelfKernelValue = 0;
    fUpSelfKernelValue = hessianDiag[m_nIndexofSampleOne];
    //select second sample

    upValue = -fMinValue;

    //get block level min (-b_ij*b_ij/a_ij)
    GetBlockMinLowValue << < gridSize, BLOCK_SIZE >> >
                                       (devYiGValue, devAlpha, devLabel, param.C, trainingSize, devHessianDiag,
                                               devHessianSampleRow1, upValue, fUpSelfKernelValue, devBlockMin, devBlockMinGlobalKey,
                                               devBlockMinYiFValue);

    //get global min
    GetGlobalMin << < 1, BLOCK_SIZE >> >
                         (devBlockMin, devBlockMinGlobalKey,
                                 numOfBlock, devYiGValue, devHessianSampleRow1, devBuffer);

    //get global min YiFValue
    //0 is the size of dynamically allocated shared memory inside kernel
    GetGlobalMin << < 1, BLOCK_SIZE >> > (devBlockMinYiFValue, numOfBlock, devBuffer);

//	cudaThreadSynchronize();
    //copy result back to host
    checkCudaErrors(cudaMemcpy(hostBuffer, devBuffer, sizeof(float_point) * 4, cudaMemcpyDeviceToHost));
    int m_nIndexofSampleTwo = int(hostBuffer[0]);

    //get kernel value K(Sample1, Sample2)
    float_point fKernelValue = 0;
    float_point fMinLowValue;
    fMinLowValue = hostBuffer[1];
    fKernelValue = hostBuffer[2];


    float_point *devHessianSampleRow2 = devHessianMatrixCache + getHessianRow(m_nIndexofSampleTwo);
//	cudaDeviceSynchronize();


    lowValue = -hostBuffer[3];
    //check if the problem is converged
    if (upValue + lowValue <= EPS) {
        //cout << upValue << " : " << lowValue << endl;
        //m_pGPUCache->PrintCachingStatistics();
        return true;
    }

    float_point fY1AlphaDiff, fY2AlphaDiff;
    updateTwoWeight(fMinLowValue, fMinValue, m_nIndexofSampleOne, m_nIndexofSampleTwo, fKernelValue,
                    fY1AlphaDiff, fY2AlphaDiff, subProblem.v_nLabels.data());
    float_point fAlpha1 = alpha[m_nIndexofSampleOne];
    float_point fAlpha2 = alpha[m_nIndexofSampleTwo];

    gpuCache->UnlockCacheEntry(m_nIndexofSampleOne);

    //update yiFvalue
    //copy new alpha values to device
    hostBuffer[0] = m_nIndexofSampleOne;
    hostBuffer[1] = fAlpha1;
    hostBuffer[2] = m_nIndexofSampleTwo;
    hostBuffer[3] = fAlpha2;
    checkCudaErrors(cudaMemcpy(devBuffer, hostBuffer, sizeof(float_point) * 4, cudaMemcpyHostToDevice));
    UpdateYiFValueKernel << < gridSize, BLOCK_SIZE >> > (devAlpha, devBuffer, devYiGValue,
            devHessianSampleRow1, devHessianSampleRow2,
            fY1AlphaDiff, fY2AlphaDiff, trainingSize);
    return false;
}

void MultiSmoSolver::init4Training(const SvmProblem &subProblem) {


    unsigned int trainingSize = subProblem.getNumOfSamples();
    checkCudaErrors(cudaMalloc((void **) &devAlpha, sizeof(float_point) * trainingSize));
    alpha = vector<float_point>(trainingSize,0);

    checkCudaErrors(cudaMalloc((void **) &devYiGValue, sizeof(float_point) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devLabel, sizeof(int) * trainingSize));

    checkCudaErrors(cudaMemset(devAlpha, 0, sizeof(float_point) * trainingSize));
    vector<float_point> revertLabel(trainingSize);
    for (int i = 0; i < trainingSize; ++i) {
        revertLabel[i] = -subProblem.v_nLabels[i];
    }
    checkCudaErrors(cudaMemcpy(devYiGValue, revertLabel.data(), sizeof(float_point) * trainingSize,
                               cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(devLabel, subProblem.v_nLabels.data(), sizeof(int) * trainingSize, cudaMemcpyHostToDevice));

    numOfBlock = Ceil(trainingSize, BLOCK_SIZE);
    gridSize = dim3(numOfBlock > NUM_OF_BLOCK ? NUM_OF_BLOCK : numOfBlock, Ceil(numOfBlock, NUM_OF_BLOCK));
    checkCudaErrors(cudaMalloc((void **) &devBlockMin, sizeof(float_point) * numOfBlock));
    checkCudaErrors(cudaMalloc((void **) &devBlockMinGlobalKey, sizeof(int) * numOfBlock));
    checkCudaErrors(cudaMalloc((void **) &devBlockMinYiFValue, sizeof(float_point) * numOfBlock));
    checkCudaErrors(cudaMalloc((void **) &devMinValue, sizeof(float_point)));
    checkCudaErrors(cudaMalloc((void **) &devMinKey, sizeof(int)));
    checkCudaErrors(cudaMalloc((void **) &devBuffer, sizeof(float_point) * 5));

    checkCudaErrors(cudaMallocHost((void **) &hostBuffer, sizeof(float_point) * 5));

    int cacheSize = CACHE_SIZE * 1024 * 256 / trainingSize;
    gpuCache = new CLATCache(subProblem.getNumOfSamples());
    gpuCache->SetCacheSize(cacheSize);
    gpuCache->InitializeCache(cacheSize, trainingSize);
    size_t sizeOfEachRowInCache;
    checkCudaErrors(
            cudaMallocPitch((void **) &devHessianMatrixCache, &sizeOfEachRowInCache, trainingSize * sizeof(float_point),
                            cacheSize));
    //temp memory for reading result to cache
    numOfElementEachRowInCache = sizeOfEachRowInCache / sizeof(float_point);
    if (numOfElementEachRowInCache != trainingSize) {
        cout << "cache memory aligned to: " << numOfElementEachRowInCache
             << "; number of the training instances is: " << trainingSize << endl;
    }
    cout << "cache size v.s. ins is " << cacheSize << " v.s. " << trainingSize << endl;

    checkCudaErrors(cudaMemset(devHessianMatrixCache, 0, cacheSize * sizeOfEachRowInCache));

    hessianDiag = new float_point[trainingSize];
    checkCudaErrors(cudaMalloc((void **) &devHessianDiag, sizeof(float_point) * trainingSize));
    hessianCalculator = new DeviceHessianOnFly(subProblem, param.gamma);
    hessianCalculator->GetHessianDiag("", trainingSize, hessianDiag);
    checkCudaErrors(
            cudaMemcpy(devHessianDiag, hessianDiag, sizeof(float_point) * trainingSize, cudaMemcpyHostToDevice));
}

void MultiSmoSolver::deinit4Training() {
    checkCudaErrors(cudaFree(devAlpha));
    checkCudaErrors(cudaFree(devYiGValue));
    checkCudaErrors(cudaFree(devLabel));
    checkCudaErrors(cudaFree(devBlockMin));
    checkCudaErrors(cudaFree(devBlockMinGlobalKey));
    checkCudaErrors(cudaFree(devBlockMinYiFValue));
    checkCudaErrors(cudaFree(devMinValue));
    checkCudaErrors(cudaFree(devMinKey));
    checkCudaErrors(cudaFree(devBuffer));
    checkCudaErrors(cudaFreeHost(hostBuffer));
    checkCudaErrors(cudaFree(devHessianMatrixCache));
    checkCudaErrors(cudaFree(devHessianDiag));
    delete hessianCalculator;
    delete[] hessianDiag;
}

int MultiSmoSolver::getHessianRow(int rowIndex) {
    int cacheLocation;
    bool cacheFull = false;
    bool cacheHit = gpuCache->GetDataFromCache(rowIndex,cacheLocation,cacheFull);
    if (!cacheHit) {
        if (cacheFull)
            gpuCache->ReplaceExpired(rowIndex, cacheLocation, NULL);
        hessianCalculator->ReadRow(rowIndex, devHessianMatrixCache + cacheLocation * numOfElementEachRowInCache);
    }
    return cacheLocation * numOfElementEachRowInCache;
}

void MultiSmoSolver::updateTwoWeight(float_point fMinLowValue, float_point fMinValue, int nHessianRowOneInMatrix,
                                     int nHessianRowTwoInMatrix, float_point fKernelValue, float_point &fY1AlphaDiff,
                                     float_point &fY2AlphaDiff, const int *label) {
    //get YiGValue for sample one and two
    float_point fAlpha2 = 0;
    float_point fYiFValue2 = 0;
    fAlpha2 = alpha[nHessianRowTwoInMatrix];
    fYiFValue2 = fMinLowValue;

    //get alpha values of sample
    float_point fAlpha1 = 0;
    float_point fYiFValue1 = 0;
    fAlpha1 = alpha[nHessianRowOneInMatrix];
    fYiFValue1 = fMinValue;

    //Get K(x_up, x_up), and K(x_low, x_low)
    float_point fDiag1 = 0, fDiag2 = 0;
    fDiag1 = hessianDiag[nHessianRowOneInMatrix];
    fDiag2 = hessianDiag[nHessianRowTwoInMatrix];

    //get labels of sample one and two
    int nLabel1 = 0, nLabel2 = 0;
    nLabel1 = label[nHessianRowOneInMatrix];
    nLabel2 = label[nHessianRowTwoInMatrix];

    //compute eta
    float_point eta = fDiag1 + fDiag2 - 2 * fKernelValue;
    if (eta <= 0)
        eta = TAU;

    float_point fCost1, fCost2;
//	fCost1 = Get_C(nLabel1);
//	fCost2 = Get_C(nLabel2);
    fCost1 = fCost2 = param.C;

    //keep old yi*alphas
    fY1AlphaDiff = nLabel1 * fAlpha1;
    fY2AlphaDiff = nLabel2 * fAlpha2;

    //get new alpha values
    int nSign = nLabel2 * nLabel1;
    if (nSign < 0) {
        float_point fDelta = (-nLabel1 * fYiFValue1 - nLabel2 * fYiFValue2) / eta; //(-fYiFValue1 - fYiFValue2) / eta;
        float_point fAlphaDiff = fAlpha1 - fAlpha2;
        fAlpha1 += fDelta;
        fAlpha2 += fDelta;

        if (fAlphaDiff > 0) {
            if (fAlpha2 < 0) {
                fAlpha2 = 0;
                fAlpha1 = fAlphaDiff;
            }
        } else {
            if (fAlpha1 < 0) {
                fAlpha1 = 0;
                fAlpha2 = -fAlphaDiff;
            }
        }

        if (fAlphaDiff > fCost1 - fCost2) {
            if (fAlpha1 > fCost1) {
                fAlpha1 = fCost1;
                fAlpha2 = fCost1 - fAlphaDiff;
            }
        } else {
            if (fAlpha2 > fCost2) {
                fAlpha2 = fCost2;
                fAlpha1 = fCost2 + fAlphaDiff;
            }
        }
    } //end if nSign < 0
    else {
        float_point fDelta = (nLabel1 * fYiFValue1 - nLabel2 * fYiFValue2) / eta;
        float_point fSum = fAlpha1 + fAlpha2;
        fAlpha1 -= fDelta;
        fAlpha2 += fDelta;

        if (fSum > fCost1) {
            if (fAlpha1 > fCost1) {
                fAlpha1 = fCost1;
                fAlpha2 = fSum - fCost1;
            }
        } else {
            if (fAlpha2 < 0) {
                fAlpha2 = 0;
                fAlpha1 = fSum;
            }
        }
        if (fSum > fCost2) {
            if (fAlpha2 > fCost2) {
                fAlpha2 = fCost2;
                fAlpha1 = fSum - fCost2;
            }
        } else {
            if (fAlpha1 < 0) {
                fAlpha1 = 0;
                fAlpha2 = fSum;
            }
        }
    }//end get new alpha values

    alpha[nHessianRowOneInMatrix] = fAlpha1;
    alpha[nHessianRowTwoInMatrix] = fAlpha2;

    //get alpha difference
    fY1AlphaDiff = nLabel1 * fAlpha1 - fY1AlphaDiff; //(alpha1' - alpha1) * y1
    fY2AlphaDiff = nLabel2 * fAlpha2 - fY2AlphaDiff;
}

void MultiSmoSolver::extractModel(const SvmProblem &subProblem, vector<int> &svIndex, vector<float_point> &coef,
                                  float_point &rho) const {
    const unsigned int trainingSize = subProblem.getNumOfSamples();
    vector<float_point> alpha(trainingSize);
    const vector<int> &label = subProblem.v_nLabels;
    checkCudaErrors(cudaMemcpy(alpha.data(), devAlpha, sizeof(float_point) * trainingSize, cudaMemcpyDeviceToHost));
    for (int i = 0; i < trainingSize; ++i) {
        if (alpha[i] != 0) {
            coef.push_back(label[i] * alpha[i]);
            svIndex.push_back(i);
        }
    }
    rho = (lowValue - upValue) / 2;
    printf("# of SV %lu\nbias = %f\n", svIndex.size(), rho);
}
