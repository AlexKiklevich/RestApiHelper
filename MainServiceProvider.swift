//
//  MainServiceProvider.swift
//
//  Created by Aliaksandr Kiklevich on 7/24/19.
//  Copyright © 2019 kiklevich alex. All rights reserved.
//

import Foundation
import Moya

protocol IMainServiceProvider {
    
    associatedtype XPSTarget: IXPSTargetType
    
    func request<T: Decodable>(_ target: XPSTarget,
                               type: T.Type,
                               completion: @escaping (T) -> Void,
                               failure: ((MoyaError?) -> Void)?) -> Cancellable?
    
    func cancelAll()
}

class MainServiceProvider<XPSTarget: IXPSTargetType> {
    
    // MARK: - Internal variables
    
    let moyaProvider: MoyaProvider<XPSTarget>
    
    // MARK: - Private constants
    
    private let coreProvider: ICoreProvider = inject()
    private let dataBaseProvider: IDataBaseProvider = inject()
    private let formatter = DateTimeFormatterManager.shared.dateTimeWithSecondsFormatter
    private let errorProcessor: ErrorProcessor = inject()
    
    // MARK: - Private variables
    
    private lazy var userNoticeSystem: IUserNoticeSystem = inject()
    
    // MARK: - Initialization
    
    init() {
        
        moyaProvider = MoyaProvider<XPSTarget>.configureProvider(
            serverName: XPSTarget.serverName,
            sessionConfiguration: XPSTarget.sessionConfiguration,
            progressViewActivityClosure: { (activity, target) in
                
                let progressViewListener: IRestLoadingProgressNotifySystem = inject()
                
                if let exchangeTraget = target as? ExchangeService {
                    
                    switch exchangeTraget {
                    case .exchange:
                        return
                    case .ratesCollection:
                        switch activity {
                        
                        case .began:
                            progressViewListener.startRestLoading()
                            
                        case .ended:
                            progressViewListener.stopRestLoading()
                        }
                    }
                    
                } else if let _ = target as? TransferService {
                    
                    switch activity {
                    
                    case .began:
                        progressViewListener.startRestLoading()
                        
                    case .ended:
                        progressViewListener.stopRestLoading()
                    }
                    
                } else if let financeTraget = target as? FinanceService {
                    
                    switch financeTraget {
                    
                    case .operationsChain:
                        return
                    default:
                        switch activity {
                        
                        case .began:
                            progressViewListener.startRestLoading()
                            
                        case .ended:
                            progressViewListener.stopRestLoading()
                        }
                    }
                } else {
                    
                    switch activity {
                    
                    case .began:
                        progressViewListener.startRestLoading()
                        
                    case .ended:
                        progressViewListener.stopRestLoading()
                    }
                }
            }
        )
    }
}

// MARK: - IMainServiceProvider

extension MainServiceProvider: IMainServiceProvider {
    
    @discardableResult
    func request<T: Decodable>(
        _ target: XPSTarget,
        type: T.Type,
        completion: @escaping (T) -> Void,
        failure: ((MoyaError?) -> Void)?
    ) -> Cancellable? {
        
        var cancellable: Cancellable?
        
        let requestTime = Date()
        
        if coreProvider.reachabilityManager.isReachable {
            
            logRequestSent(
                url: target.baseURL.absoluteString + target.path,
                requestTime: requestTime
            )
            
            cancellable = moyaProvider.request(target) { [weak self] result in
                
                cancellable = nil
                
                switch result {
                
                case let .success(response):
                    
                    self?.logRequestSuccessful(
                        url: target.baseURL.absoluteString + target.path,
                        requestTime: Date()
                    )
                    
                    do {
                        
                        let data = try JSONDecoder().decode(
                            T.self,
                            from: response.data
                        )
                        completion(data)
                        
                    } catch let error {
                        
                        failure?(nil)
                        
                        self?.notificateUserAboutError(
                            url: target.baseURL.absoluteString + target.path,
                            errorCode: (error as NSError).code,
                            errorDescription: error.localizedDescription,
                            requestTime: requestTime
                        )
                    }
                    
                case let .failure(error):
                    
                    failure?(error)
                    
                    self?.handleMoyaError(
                        error,
                        target: target,
                        requestTime: requestTime
                    )
                }
            }
        }
        
        return cancellable
    }
    
    func cancelAll() {
        
        moyaProvider.session.session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }
}

// MARK: - Error handling

private extension MainServiceProvider {
    
    func handleMoyaError(_ moyaError: MoyaError,
                         target: XPSTarget,
                         requestTime: Date) {
        
        notificateUserAboutMoyaError(moyaError,
                                     target: target,
                                     requestTime: requestTime)
    }
}

// MARK: - Error notificating

private extension MainServiceProvider {
    
    func notificateUserAboutMoyaError(_ moyaError: MoyaError,
                                      target: XPSTarget,
                                      requestTime: Date) {

        checkAuth(moyaError)
        
        let message = errorProcessor.getMoyaErrorMessage(error: moyaError)
        userNoticeSystem.displayMessage(
            message,
            messageType: .error,
            priority: .restInitiated,
            autotestIdentifier: "RestErrorNotificationBanner"
        )
        
        if let logType = target.getErrorLogObjectType(
            withError: moyaError,
            requestTime: formatter.string(from: requestTime),
            responseTime: formatter.string(from: Date())) {
            
            log(LogFormatter.logObject(type: logType))
        }
    }
    
    func notificateUserAboutError(url: String,
                                  errorCode: Int,
                                  errorDescription: String,
                                  requestTime: Date) {
        
        userNoticeSystem.displayMessage(
            errorDescription,
            messageType: .error,
            priority: .normal,
            autotestIdentifier: "RestErrorNotificationBanner"
        )
        
        let logType = LogObjectType.requestError(
            url: url,
            errorCode: errorCode,
            errorDescription: errorDescription,
            requestTime: formatter.string(from: requestTime),
            responseTime: formatter.string(from: Date())
        )
        
        log(LogFormatter.logObject(type: logType))
    }
    
    func checkAuth(_ error: MoyaError) {
        
        let code = errorProcessor.getMoyaErrorCode(error: error)
        if code == "EXTERNAL_DEVICE_AUTHENTICATION_FAILED" || code == "AUTHENTICATION_FAILED" {
            cancelAll()
            coreProvider.processInvalidAuthenticationInfoError()
        }
    }
}

// MARK: - Logging

extension MainServiceProvider {
    
    func logRequestSent(url: String,
                        requestTime: Date) {
        
        let logType = LogObjectType.requestSent(
            url: url,
            requestTime: formatter.string(from: requestTime)
        )
        
        log(LogFormatter.logObject(type: logType))
    }
    
    func logRequestSuccessful(url: String,
                              requestTime: Date) {
        
        let logType = LogObjectType.requestSuccessful(
            url: url,
            requestTime: formatter.string(from: requestTime)
        )
        
        log(LogFormatter.logObject(type: logType))
    }
    
    func log(_ logObject: LogObject) {
        
        let provider = dataBaseProvider.logRealmProvider
        
        provider.write(element: logObject, failure: nil)
    }
}
